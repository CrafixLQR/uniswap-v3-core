// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

// 导入相关接口和库
import './interfaces/IUniswapV3Pool.sol';    // 池子接口
import './NoDelegateCall.sol';               // 防止委托调用的合约

// 导入数学计算相关库
import './libraries/LowGasSafeMath.sol';     // 低gas消耗的安全数学运算库
import './libraries/SafeCast.sol';           // 安全类型转换库
import './libraries/Tick.sol';               // tick操作相关库
import './libraries/TickBitmap.sol';         // tick位图操作库
import './libraries/Position.sol';           // 头寸管理库
import './libraries/Oracle.sol';             // 预言机库

// 导入更多数学计算相关库
import './libraries/FullMath.sol';           // 完整数学运算库
import './libraries/FixedPoint128.sol';      // 定点数运算库
import './libraries/TransferHelper.sol';      // 代币转账帮助库
import './libraries/TickMath.sol';           // tick数学运算库
import './libraries/LiquidityMath.sol';      // 流动性数学运算库
import './libraries/SqrtPriceMath.sol';      // 价格开方数学运算库
import './libraries/SwapMath.sol';           // 交换数学运算库

// 导入回调接口
import './interfaces/IUniswapV3PoolDeployer.sol';    // 池子部署器接口
import './interfaces/IUniswapV3Factory.sol';         // 工厂合约接口
import './interfaces/IERC20Minimal.sol';             // 最小化ERC20接口
import './interfaces/callback/IUniswapV3MintCallback.sol';    // 铸造回调接口
import './interfaces/callback/IUniswapV3SwapCallback.sol';    // 交换回调接口
import './interfaces/callback/IUniswapV3FlashCallback.sol';   // 闪电贷回调接口

// UniswapV3Pool 合约定义，继承自池子接口和防委托调用合约
contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    // 使用各种库
    using LowGasSafeMath for uint256;    // 为 uint256 类型添加低gas安全数学运算方法
    using LowGasSafeMath for int256;     // 为 int256 类型添加低gas安全数学运算方法
    using SafeCast for uint256;          // 为 uint256 类型添加安全转换方法
    using SafeCast for int256;           // 为 int256 类型添加安全转换方法
    using Tick for mapping(int24 => Tick.Info);              // 为 tick映射添加操作方法
    using TickBitmap for mapping(int16 => uint256);         // 为 tick位图添加操作方法
    using Position for mapping(bytes32 => Position.Info);    // 为头寸映射添加操作方法
    using Position for Position.Info;                        // 为头寸信息添加操作方法
    using Oracle for Oracle.Observation[65535];              // 为预言机观察数组添加操作方法

    // 不可变状态变量声明
    address public immutable override factory;    // 工厂合约地址
    address public immutable override token0;     // 代币0地址
    address public immutable override token1;     // 代币1地址
    uint24 public immutable override fee;         // 交易手续费率

    int24 public immutable override tickSpacing;  // tick间距
    uint128 public immutable override maxLiquidityPerTick;  // 每个tick的最大流动性

    // Slot0 结构体存储池子的关键状态变量
    struct Slot0 {
        /**
         * 当前价格的平方根，使用Q96.64格式
         * Q96.64 是一种定点数(Fixed Point)
         * 总位数：160位 (一个 uint160)
         * 低64位（小数）
         * 高96位（整数）
         */
        uint160 sqrtPriceX96;
        int24 tick;              // 当前的tick值
        uint16 observationIndex; // 最近更新的预言机观察值索引
        uint16 observationCardinality;    // 当前存储的观察值数量
        uint16 observationCardinalityNext;  // 下一次写入时的最大观察值数量
        uint8 feeProtocol;       // 协议费率，表示为分数(1/x)%
        bool unlocked;           // 池子是否被锁定（重入锁）
    }
    
    // 全局状态变量
    Slot0 public override slot0;  // 存储池子的当前状态

    // 全局累计费用，使用Q128.128格式
    uint256 public override feeGrowthGlobal0X128;  // token0的累计费用
    uint256 public override feeGrowthGlobal1X128;  // token1的累计费用

    // 协议费用结构体
    struct ProtocolFees {
        uint128 token0;    // token0的协议费用
        uint128 token1;    // token1的协议费用
    }
    ProtocolFees public override protocolFees;  // 存储协议收取的费用

    // 当前池子的流动性
    uint128 public override liquidity;

    // 映射存储
    mapping(int24 => Tick.Info) public override ticks;        // tick => tick信息
    mapping(int16 => uint256) public override tickBitmap;     // tick位图，用于快速查找已初始化的tick

   /**
     * @notice LP（流动性提供者）头寸信息映射
     * @dev 键值(bytes32)由三个参数计算得出：
     *   - owner: LP的地址
     *   - tickLower: 价格区间下限的tick值
     *   - tickUpper: 价格区间上限的tick值
     * 
     * Position.Info 存储以下信息：
     *   - liquidity: LP提供的流动性数量
     *   - feeGrowthInside0LastX128: 上次更新时token0的费用累计值
     *   - feeGrowthInside1LastX128: 上次更新时token1的费用累计值
     *   - tokensOwed0: LP待领取的token0数量
     *   - tokensOwed1: LP待领取的token1数量
     * 
     * 特点：
     * 1. 同一个LP可以在不同价格区间创建多个头寸
     * 2. 不同LP可以在相同价格区间创建头寸
     * 3. 每个头寸独立计算和领取手续费
     */
    mapping(bytes32 => Position.Info) public override positions;  // 头寸信息

    Oracle.Observation[65535] public override observations;    // 预言机历史数据

    // 重入锁修饰符
    modifier lock() {
        require(slot0.unlocked, 'LOK');    // 确保未锁定
        slot0.unlocked = false;            // 上锁
        _;                                 // 执行函数
        slot0.unlocked = true;             // 解锁
    }

    // 仅工厂合约所有者可调用的修饰符
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

   // 构造函数：初始化池子的基本参数
    constructor() {
        int24 _tickSpacing;
        // 从部署器合约获取初始化参数
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;

        // 根据tick间距计算每个tick的最大流动性
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    // 检查tick范围的有效性
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');    // 确保下限小于上限
        require(tickLower >= TickMath.MIN_TICK, 'TLM');    // 确保下限不小于最小tick
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');    // 确保上限不大于最大tick
    }

    // 获取当前区块时间戳（32位）
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // 截断为32位
    }

    // 获取池子中token0的余额
    function balance0() private view returns (uint256) {
        // 使用staticcall调用token0的balanceOf函数
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    // 获取池子中token1的余额
    function balance1() private view returns (uint256) {
        // 使用staticcall调用token1的balanceOf函数
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

     // 获取指定tick区间内的累计值快照
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        override
        noDelegateCall
        returns (
            int56 tickCumulativeInside,      // tick累计值
            uint160 secondsPerLiquidityInsideX128,  // 每单位流动性的秒数
            uint32 secondsInside             // 区间内的总秒数
        )
    {
        // 验证tick范围
        checkTicks(tickLower, tickUpper);

        // 获取区间边界的累计值
        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            // 获取区间边界的tick信息
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            // 获取下边界tick的累计值
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);  // 确保下边界tick已初始化

            // 获取上边界tick的累计值
            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);  // 确保上边界tick已初始化
        }

        // 获取当前状态
        Slot0 memory _slot0 = slot0;

        // 根据当前tick位置计算区间内的累计值
        if (_slot0.tick < tickLower) {
            // 当前tick在区间下方
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            // 当前tick在区间内
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    _slot0.tick,
                    _slot0.observationIndex,
                    liquidity,
                    _slot0.observationCardinality
                );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            // 当前tick在区间上方
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    // 观察历史价格数据
    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        // 调用预言机库获取历史数据
        return
            observations.observe(
                _blockTimestamp(),    // 当前时间戳
                secondsAgos,          // 要查询的历史时间点数组
                slot0.tick,           // 当前tick
                slot0.observationIndex,  // 当前观察值索引
                liquidity,            // 当前流动性
                slot0.observationCardinality  // 观察值数量
            );
    }

    // 增加预言机观察值的容量
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext)
        external
        override
        lock
        noDelegateCall
    {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;  // 记录旧值
        // 扩展观察值数组
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        // 如果容量确实改变了，则触发事件
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    /**
     * 初始化池子 
     * @param sqrtPriceX96 初始价格的平方根
     */
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, 'AI');  // 确保未初始化

        // 计算初始价格对应的tick
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        // 初始化预言机
        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        // 初始化slot0状态
        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,          // 初始价格
            tick: tick,                           // 初始tick
            observationIndex: 0,                  // 观察值索引从0开始
            observationCardinality: cardinality,  // 观察值容量
            observationCardinalityNext: cardinalityNext,  // 下一次的观察值容量
            feeProtocol: 0,                      // 协议费率初始为0
            unlocked: true                       // 初始未锁定
        });

        emit Initialize(sqrtPriceX96, tick);  // 触发初始化事件
    }

    // 修改头寸的参数结构体
    struct ModifyPositionParams {
        address owner;           // 头寸所有者
        int24 tickLower;        // 价格区间下限
        int24 tickUpper;        // 价格区间上限
        int128 liquidityDelta;  // 流动性变化值（正数增加，负数减少）
    }

    // 修改头寸的内部函数
    function _modifyPosition(ModifyPositionParams memory params)
        private
        noDelegateCall
        returns (
            Position.Info storage position,  // 返回修改后的头寸信息
            int256 amount0,                 // token0 的数量变化
            int256 amount1                  // token1 的数量变化
        )
    {
        checkTicks(params.tickLower, params.tickUpper);  // 检查tick范围有效性
        Slot0 memory _slot0 = slot0;  // 加载当前状态

        // 更新头寸信息
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        // 如果流动性有变化，计算所需代币数量
        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // 当前价格低于区间，只需要token0
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // 当前价格在区间内，需要两种代币
                uint128 liquidityBefore = liquidity;

                // 更新预言机数据
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                // 计算所需代币数量
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                // 更新全局流动性
                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // 当前价格高于区间，只需要token1
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    // 更新头寸信息的内部函数
    function _updatePosition(
        address owner,          // 头寸所有者
        int24 tickLower,       // 价格区间下限
        int24 tickUpper,       // 价格区间上限
        int128 liquidityDelta, // 流动性变化值
        int24 tick            // 当前tick
    ) private returns (Position.Info storage position) {
        // 获取头寸信息
        position = positions.get(owner, tickLower, tickUpper);

        // 加载全局费用累计值（gas优化）
        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128;

        // 如果流动性有变化，需要更新tick状态
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            // 获取当前累计值
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );

            // 更新下限tick
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                maxLiquidityPerTick
            );

            // 更新上限tick
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                maxLiquidityPerTick
            );

            // 如果tick状态发生翻转，更新位图
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 计算区间内的费用累计值
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        // 更新头寸信息
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // 如果是移除流动性，清理不再需要的tick数据
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    // 铸造新的流动性头寸
    function mint(
        address recipient,      // 接收者地址
        int24 tickLower,       // 价格区间下限
        int24 tickUpper,       // 价格区间上限
        uint128 amount,        // 流动性数量
        bytes calldata data    // 回调数据
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);    // 流动性必须大于0
        
        // 调用修改头寸函数增加流动性
        (, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: recipient,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(amount).toInt128()
                })
            );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // 检查代币转入
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    // 收集已赚取的费用
    function collect(
        address recipient,          // 接收者地址
        int24 tickLower,           // 价格区间下限
        int24 tickUpper,           // 价格区间上限
        uint128 amount0Requested,   // 请求提取的token0数量
        uint128 amount1Requested    // 请求提取的token1数量
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // 获取头寸信息
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        // 计算实际可提取数量
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        // 转移代币
        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    // 销毁流动性头寸
    function burn(
        int24 tickLower,    // 价格区间下限
        int24 tickUpper,    // 价格区间上限
        uint128 amount      // 销毁的流动性数量
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        // 调用修改头寸函数减少流动性
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(amount).toInt128()
                })
            );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        // 更新待领取的代币数量
        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

     // 交易缓存结构体，用于存储交易过程中的临时数据，避免重复计算和多次读取存储
    struct SwapCache {
        // 协议费率：
        // - 当 zeroForOne 为 true 时，取 feeProtocol 的低 4 位 (% 16)
        // - 当 zeroForOne 为 false 时，取 feeProtocol 的高 4 位 (>> 4)
        // 用于计算协议收取的手续费份额
        uint8 feeProtocol;          

        // 交易开始时的流动性总量
        // 记录初始状态，用于计算价格影响和费用分配
        uint128 liquidityStart;     

        // 当前区块的时间戳
        // 用于更新预言机数据和计算时间加权平均价格
        uint32 blockTimestamp;      

        // tick 的累计值
        // 用于计算时间加权平均价格，跟踪价格变化历史
        int56 tickCumulative;       

        // 每单位流动性的累计秒数（Q128.128格式）
        // 用于计算流动性提供者的收益
        uint160 secondsPerLiquidityCumulativeX128;  

        // 是否已经计算了最新的观察值
        // 用于确保在跨越已初始化的 tick 时只计算一次最新观察值
        bool computedLatestObservation;  
    }

    // 交易状态结构体，用于追踪和存储交易执行过程中的各种状态
    struct SwapState {
        // 剩余需要交换的代币数量
        // - 对于精确输入(exactInput): 剩余需要投入的代币数量
        // - 对于精确输出(exactOutput): 剩余需要获得的代币数量
        // 随着交易进行会逐步减少至0
        int256 amountSpecifiedRemaining;  

        // 已计算出的交换数量
        // - 对于精确输入: 累计获得的输出代币数量（负数）
        // - 对于精确输出: 累计需要的输入代币数量（正数）
        int256 amountCalculated;          

        // 当前价格的平方根，使用Q96.64格式
        // 在交易过程中会随着流动性变化而更新
        uint160 sqrtPriceX96;             

        // 当前价格对应的tick值
        // 用于在tick范围内定位当前价格位置
        int24 tick;                       

        // 全局累计费用
        // 根据交易方向选择对应代币的费用累计值
        // - zeroForOne为true时使用token0的费用累计
        // - zeroForOne为false时使用token1的费用累计
        uint256 feeGrowthGlobalX128;      

        // 本次交易累计的协议费用
        // 从交易费用中抽取一部分作为协议费用
        uint128 protocolFee;              

        // 当前可用的流动性
        // 随着价格变化跨越不同tick时会更新
        uint128 liquidity;                
    }

    // 单步交易计算结果结构体
    // 用于存储在执行交易过程中，每一步价格变动的计算结果
    struct StepComputations {
        // 当前步骤开始时的价格
        // 使用Q96.64格式存储价格的平方根
        // 在跨越不同tick时会发生变化
        uint160 sqrtPriceStartX96;    

        // 下一个需要处理的tick值
        // 通过tickBitmap查找得到
        // 用于确定价格变动的边界
        int24 tickNext;               

        // 下一个tick是否已被初始化
        // 如果已初始化，说明这个tick上有流动性
        // 需要在跨越时更新流动性状态
        bool initialized;             

        // 下一个tick对应的价格
        // 也是使用Q96.64格式存储价格的平方根
        // 用于计算这一步可以交易的数量
        uint160 sqrtPriceNextX96;     

        // 这一步实际投入的代币数量
        // 不包含手续费
        uint256 amountIn;             

        // 这一步实际获得的代币数量
        uint256 amountOut;            

        // 这一步产生的手续费数量
        // 用于更新全局费用状态和计算协议费
        uint256 feeAmount;            
    }

    // 
    /**
     * 执行交易
     * @param recipient 接收者地址
     * @param zeroForOne 交易方向（true: token0->token1）
     * @param amountSpecified 指定的交易数量（正数表示精确输入，负数表示精确输出）
     *   分为正负数
     *      - 传入正数（精确输入）：我有1000个USDT，能换多少ETH都行，但我确定要用这1000个USDT去换
     *      - 传入负数（精确输出）：我要买1个ETH，需要多少USDT都行，但我确定要得到这1个ETH
     * @param sqrtPriceLimitX96 价格限制（滑点）
     * @param data 回调数据
     */
    function swap(
        address recipient,           // 接收者地址
        bool zeroForOne,            // 交易方向（true: token0->token1）
        int256 amountSpecified,     // 指定的交易数量（正数表示精确输入，负数表示精确输出）
        uint160 sqrtPriceLimitX96,  // 价格限制（滑点）
        bytes calldata data         // 回调数据
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, 'AS');  // 交易数量不能为0

        // 记录交易开始时的状态
        Slot0 memory slot0Start = slot0;

        // 检查重入锁和价格限制
        require(slot0Start.unlocked, 'LOK');

        /**
         * 防止三明治攻击
         * 滑点价格必须在当前价格的上下范围内
         * 
         */
        require(
            zeroForOne  // 如果是 token0 换 token1
            ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 // 滑点价格必须低于当前价格
                && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO  // 但不能低于最小允许价格
            : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96  // 滑点价格必须高于当前价格
                && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO, // 但不能高于最大允许价格
            'SPL'  // SPL = Sqrt Price Limit
        );

        slot0.unlocked = false;  // 上锁

        // 初始化交易缓存
        SwapCache memory cache = SwapCache({
            liquidityStart: liquidity,  // 记录当前池子的流动性
            blockTimestamp: _blockTimestamp(),  // 获取当前区块时间戳
            // 根据交易方向选择对应的协议费率
            // slot0 中的 feeProtocol 是一个 uint8，使用位压缩存储两个费率：
            // - 低4位(0-3位) 存储 token0 的协议费率
            // - 高4位(4-7位) 存储 token1 的协议费率
            feeProtocol: zeroForOne 
                ? (slot0Start.feeProtocol % 16)   // 如果是 token0 换 token1，取低4位
                : (slot0Start.feeProtocol >> 4),  // 如果是 token1 换 token0，取高4位
            secondsPerLiquidityCumulativeX128: 0,  // 初始化为 0
            tickCumulative: 0,  // 初始化为 0
            computedLatestObservation: false  // 初始化为 false
        });
        
        // 判断是否为精确输入交易
        bool exactInput = amountSpecified > 0; 

       // 初始化交易状态
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,  // 初始化为用户指定的交易数量
            amountCalculated: 0,                        // 初始化为0
            sqrtPriceX96: slot0Start.sqrtPriceX96,     // 使用当前池子的价格
            tick: slot0Start.tick,                      // 使用当前池子的tick
            // 根据交易方向选择对应的费用累计值
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            protocolFee: 0,                             // 初始化协议费用为0
            liquidity: cache.liquidityStart             // 使用当前池子的流动性
        });

        /**
         * 循环执行交易步骤
         * 直到达到购买的数量或价格（滑点）限制
         */
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step; // 初始化交易步骤
            step.sqrtPriceStartX96 = state.sqrtPriceX96; // 记录当前价格

            // 获取下一个初始化的tick
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,  // 当前tick
                tickSpacing, // tick间距
                zeroForOne // 交易方向
            );

            // 确保不超出tick范围
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // 获取下一个tick的价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // 
            /**
             * 计算当前步骤的交易结果
             */
            (
                state.sqrtPriceX96, // 更新后的价格
                step.amountIn, // 实际投入的代币数量
                step.amountOut, // 实际获得的代币数量
                step.feeAmount // 产生的手续费数量
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96, // 当前价格

                // 
                /**
                 * 如果交易详细是token0->token1？当前下一步的价格小于滑点价格：当前价格大于滑点价格
                 * 当 zeroForOne = true （用 token0 换 token1）时：
                 * 如果下一个tick价格( step.sqrtPriceNextX96 ) < 滑点限制价格( sqrtPriceLimitX96 )
                 * 说明继续交易会超出用户设置的最低价格限制
                 * 
                 * 当 zeroForOne = false （用 token1 换 token0）时：
                 * 如果下一个tick价格( step.sqrtPriceNextX96 ) > 滑点限制价格( sqrtPriceLimitX96 )
                 * 说明继续交易会超出用户设置的最高价格限制
                 */
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96 // 滑点价格
                    : step.sqrtPriceNextX96, // 下一个tick的价格
                state.liquidity, // 当前流动性
                state.amountSpecifiedRemaining, // 剩余需要交换的代币数量
                fee // 交易手续费
            );

            // 更新剩余数量和已计算数量

            // 如果是精确输入交易
            if (exactInput) {
                // 剩余需要交换的代币数量 -= （实际投入的代币数量 + 产生的手续费数量）
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                // 已计算出的交换数量 = （已计算出的交换数量 - 实际获得的代币数量）
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                // 剩余需要交换的代币数量 += 实际获得的代币数量
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                // 已计算出的交换数量 = （已计算出的交换数量 + 实际投入的代币数量 + 产生的手续费数量）
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            /**
             * 计算协议费用
             * cache.feeProtocol 的取值范围是 4-10，表示协议将收取 1/4 到 1/10 的手续费
             * 例如：feeProtocol = 5 表示协议将收取 1/5 的手续费
             */
            if (cache.feeProtocol > 0) {

                /**
                 * 计算协议应收取的手续费数量
                 * 示例：
                 * 假设本次交易产生手续费 step.feeAmount = 1000
                 * 协议费率 cache.feeProtocol = 5
                 * 则 delta = 1000 / 5 = 200（协议收取200）
                 */
                uint256 delta = step.feeAmount / cache.feeProtocol;

                /**
                 * 从总手续费中扣除协议费用
                 * 接上例：step.feeAmount = 1000 - 200 = 800（LP获得800）
                 */
                step.feeAmount -= delta;

                /**
                 * 累加协议费用
                 * 接上例：state.protocolFee += 200
                 * 这部分费用后续可以被协议所有者通过 collectProtocol 函数提取
                 */
                state.protocolFee += uint128(delta);
            }

            // 更新全局费用
            if (state.liquidity > 0)
                // feeGrowthGlobalX128 表示每单位流动性的累计手续费
                // 计算公式：当前手续费 * Q128 / 当前流动性
                // - step.feeAmount：这一步产生的手续费（已扣除协议费用）
                // - FixedPoint128.Q128：用于定点数计算的系数（2^128）
                // - state.liquidity：当前的流动性
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

           /**
            * 
            * Oracle数据更新：记录价格和流动性的历史数据，用于计算TWAP等
            * 流动性更新：当跨越一个tick时，需要更新可用流动性
            * Tick更新：记录新的价格位置
            */
            // 当价格达到下一个tick时，需要更新相关状态
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // 如果这个tick已被初始化（即有流动性存在）
                if (step.initialized) {
                    // 第一次跨越已初始化的tick时，需要计算并更新oracle数据
                    if (!cache.computedLatestObservation) {
                        // 调用oracle获取累计数据：
                        // - tickCumulative：价格tick的时间加权累计值
                        // - secondsPerLiquidityCumulativeX128：每单位流动性的时间累计值
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,    // 当前时间戳
                            0,                       // 要查询的秒数（0表示当前）
                            slot0Start.tick,         // 起始tick
                            slot0Start.observationIndex,  // oracle数据的索引
                            cache.liquidityStart,    // 起始流动性
                            slot0Start.observationCardinality  // oracle数据的容量
                        );
                        cache.computedLatestObservation = true;  // 标记已计算
                    }

                    // 调用ticks.cross处理跨越tick时的状态更新：
                    // - 更新费用增长
                    // - 更新时间加权累计值
                    // - 返回该tick上的净流动性变化值
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,   // 要跨越的tick
                        // 根据交易方向传入相应的费用累计值
                        (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                        (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                        cache.secondsPerLiquidityCumulativeX128,  // 时间加权累计值
                        cache.tickCumulative,    // tick累计值
                        cache.blockTimestamp     // 当前时间戳
                    );

                    // 当向左移动时（价格下降，zeroForOne为true）
                    // 需要将liquidityNet取反，因为：
                    // - 向右移动时，遇到的是流动性的增加
                    // - 向左移动时，遇到的是流动性的减少
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    // 更新当前的流动性
                    // 将该tick上的净流动性变化值添加到当前流动性中
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }
                
                // 更新当前tick值
                // - 当向左移动(zeroForOne=true)时：新tick = 下一个tick - 1
                // - 当向右移动(zeroForOne=false)时：新tick = 下一个tick
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                // 如果价格发生了变化（当前价格 != 步骤开始时的价格）
                // 但又没有达到下一个 tick 边界
                // 需要重新计算当前价格对应的 tick 值
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // 如果当前tick和交易开始时的tick不同，说明价格跨越了tick边界
        if (state.tick != slot0Start.tick) {
            // 写入新的预言机观察值
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write(
                    slot0Start.observationIndex,    // 当前观察值的索引
                    cache.blockTimestamp,           // 当前时间戳
                    slot0Start.tick,                // 起始tick
                    cache.liquidityStart,           // 起始流动性
                    slot0Start.observationCardinality,    // 当前观察值容量
                    slot0Start.observationCardinalityNext // 下一次的观察值容量
                );

            // 更新全局状态slot0
            // 包括：新价格、新tick、新的观察值索引和容量
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,      // 新价格
                state.tick,              // 新tick
                observationIndex,        // 新的观察值索引
                observationCardinality   // 新的观察值容量
            );
        } else {
            // 如果tick没有改变，只需更新价格
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // 如果交易过程中流动性发生了变化，更新全局流动性状态
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        // 根据交易方向更新相应代币的费用累计值和协议费用
        if (zeroForOne) {  // 如果是用token0换token1
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;  // 更新token0的费用累计值
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;  // 更新token0的协议费用
        } else {  // 如果是用token1换token0
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;  // 更新token1的费用累计值
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;  // 更新token1的协议费用
        }

        // 根据交易类型（精确输入/精确输出）计算最终的交易数量
        (amount0, amount1) = zeroForOne == exactInput
             // 交易数量 - 剩余需要交换的代币数量 ， 已计算出的交换数量
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            // 已计算出的交换数量 ， 交易数量 - 剩余需要交换的代币数量
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // 执行代币转账
        if (zeroForOne) { // 如果是用token0换token1
            // 如果需要向用户转出token1（amount1为负数表示用户要收到token1）
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            // 记录转账前的token0余额
            uint256 balance0Before = balance0();
            // 调用回调函数，要求用户转入token0，将得到交易后的token1
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            // 确保用户确实转入了足够的token0
            // IIA = Insufficient Input Amount（输入金额不足）
            // require(池子原有余额 + 用户应转入数量 <= 池子现有余额, 'IIA')
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else { // 如果是用token1换token0
            // 如果需要向用户转出token0（amount0为负数表示用户要收到token0）
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            // 记录转账前的token1余额
            uint256 balance1Before = balance1();
            // 调用回调函数，要求用户转入token1
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            // 确保用户确实转入了足够的token1 
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        // 触发Swap事件，记录交易信息
        emit Swap(
            msg.sender,           // 交易发起者
            recipient,           // 接收者
            amount0,            // token0的数量变化
            amount1,            // token1的数量变化
            state.sqrtPriceX96, // 最终价格
            state.liquidity,    // 最终流动性
            state.tick          // 最终tick
        );

        slot0.unlocked = true;  // 解锁池子，允许下一次交易
    }

    /// @inheritdoc IUniswapV3PoolActions
    // 执行闪电贷
    function flash(
        address recipient,     // 接收者地址
        uint256 amount0,      // token0借款数量
        uint256 amount1,      // token1借款数量
        bytes calldata data   // 回调数据
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, 'L');  // 确保池子有流动性

        // 计算闪电贷手续费
        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);

        // 记录借款前的余额
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        // 转出借款金额
        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        // 调用回调函数，用户在这里执行闪电贷逻辑
        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        // 检查还款后的余额
        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        // 确保还款金额足够（本金+手续费）
        require(balance0Before.add(fee0) <= balance0After, 'F0');
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // 计算实际支付的手续费
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        // 处理token0的手续费
        if (paid0 > 0) {
            // 从slot0中获取token0的协议费率
            // slot0.feeProtocol是一个uint8，使用位压缩存储两个费率：
            // - 低4位(0-3位)存储token0的协议费率
            // - 高4位(4-7位)存储token1的协议费率
            // 通过 % 16 (即 & 0xF)获取低4位的值
            uint8 feeProtocol0 = slot0.feeProtocol % 16;  

            // 计算协议应收的手续费
            // 如果协议费率为0，则协议不收取费用
            // 否则，协议收取 1/feeProtocol0 的手续费
            // 例如：feeProtocol0 = 5 时，协议收取 1/5 的手续费
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;  

            // 如果协议费用大于0，则累加到protocolFees中
            // 这部分费用可以由协议所有者通过collectProtocol函数提取
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);  

            // 更新全局费用增长值
            // paid0 - fees0：总手续费减去协议费用，即LP应得的部分
            // 使用Q128格式存储，确保精确计算
            // 按流动性比例分配给所有LP
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }

        // 处理token1的手续费，逻辑与token0相同
        if (paid1 > 0) {
            // 从slot0中获取token1的协议费率
            // 通过 >> 4 获取高4位的值
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;  

            // 计算协议应收的手续费
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;  

            // 累加协议费用
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);  

            // 更新全局费用增长值
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    // 设置协议费用比例
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        // 验证费用比例在有效范围内：0或4-10
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        
        // 更新协议费用比例
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);  // 高4位存储token1费率，低4位存储token0费率
        
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    // 收集协议费用
    function collectProtocol(
        address recipient,          // 接收者地址
        uint128 amount0Requested,   // 请求提取的token0数量
        uint128 amount1Requested    // 请求提取的token1数量
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        // 计算实际可提取数量
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        // 处理token0
        if (amount0 > 0) {
            // 保留1个wei防止清空存储槽（gas优化）
            if (amount0 == protocolFees.token0) amount0--;
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }

        // 处理token1
        if (amount1 > 0) {
            // 保留1个wei防止清空存储槽（gas优化）
            if (amount1 == protocolFees.token1) amount1--;
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
