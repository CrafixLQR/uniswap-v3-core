// SPDX-License-Identifier: BUSL-1.1    
pragma solidity =0.7.6;                

// 工厂合约接口
import './interfaces/IUniswapV3Factory.sol';    
 // 池子部署器合约    
import './UniswapV3PoolDeployer.sol';        
 // 防止委托调用的合约     
import './NoDelegateCall.sol';    
 // 交易池合约                 
import './UniswapV3Pool.sol';    


/// @title Canonical Uniswap V3 factory
/// @notice Deploys Uniswap V3 pools and manages ownership and control over pool protocol fees
contract UniswapV3Factory is IUniswapV3Factory, UniswapV3PoolDeployer, NoDelegateCall {
    /// @inheritdoc IUniswapV3Factory
    // 合约所有者地址
    address public override owner;    

    /**
     * 交易手续费率 => tick 间距
     * 
     * 什么是 tick 间距？
     * Uniswap V3 中的价格计算公式是：price = 1.0001^tick
     * tick: 0    -> 价格: 1.0000
     * tick: 10   -> 价格: 1.0010  (上涨0.10%)
     * tick: 20   -> 价格: 1.0020  (上涨0.20%)
     * tick: -10  -> 价格: 0.9990  (下跌0.10%)
     * 
     * 为什么稳定币需要小的tick间距？
     * USDC/USDT 的价格应该始终接近 1:1 如果价格偏离 1 超过 0.1%，就会有套利机会
     * 
     * tick间距小 = 价格点密集 = 适合小波动
     * tick间距大 = 价格点稀疏 = 适合大波动
     */
    mapping(uint24 => int24) public override feeAmountTickSpacing;

    /**
     * 存储所有已创建的交易池地址
     * 代币地址1 => 代币地址2 => 手续费率 => 交易池地址
     * 
     * 创建池子时会双向记录，这样无论传入代币的顺序如何，都能找到相同的池子
     * ：
     * getPool[ETH][USDC][fee] = pool;
     * 
     * 举例：ETH/USDC 可以有三个池子
     * getPool[ETH][USDC][500]  // 0.05% 费率池
     * getPool[ETH][USDC][3000] // 0.3% 费率池
     * getPool[ETH][USDC][10000] // 1% 费率池
     */
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;

    constructor() {
        owner = msg.sender;    // 设置合约部署者为所有者
        emit OwnerChanged(address(0), msg.sender);    // 触发所有者变更事件

        // 初始化三种默认的费用等级和对应的 tick 间距
        // 0.05% 费用，tick 间距为 10
        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);
        // 0.3% 费用，tick 间距为 60
        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
        // 1% 费用，tick 间距为 200
        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    /**
     * 创建交易池
     *
     * @param tokenA 代币地址1
     * @param tokenB 代币地址2
     * @param fee 交易手续费率
     * @return pool 新创建的交易池地址
     * @modifier noDelegateCall 修饰符确保合约不能被委托调用
     */
    /// @inheritdoc IUniswapV3Factory
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external override noDelegateCall returns (address pool) {
        require(tokenA != tokenB);    // 确保两个代币地址不同
        // 将代币地址按大小排序（十六进制），确保相同的代币对总是以相同的顺序存储
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0));    // 确保代币地址不为零地址
        int24 tickSpacing = feeAmountTickSpacing[fee];    // 获取对应费用的 tick 间距
        require(tickSpacing != 0);    // 确保费用等级有效
        require(getPool[token0][token1][fee] == address(0));    // 确保池子不存在

        /**
         * 部署新的交易池合约
         * 调用 UniswapV3PoolDeployer 合约的 deploy 方法
         */
        pool = deploy(address(this), token0, token1, fee, tickSpacing);
        
        // 双向记录池子地址，方便查询
        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;
        
        // 触发池子创建事件
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /**
     * 设置新的管理员
     * @param _owner 新的管理员地址
     */
    /// @inheritdoc IUniswapV3Factory
    function setOwner(address _owner) external override {
        require(msg.sender == owner);    // 只有当前管理员可以修改
        emit OwnerChanged(owner, _owner);    // 触发管理员变更事件
        owner = _owner;    // 更新管理员地址
    }

    /**
     * 启用新的费用等级
     * @param fee 新的费用等级
     * @param tickSpacing 新的 tick 间距
     */
    /// @inheritdoc IUniswapV3Factory
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        require(msg.sender == owner);    // 只有管理员可以添加新的费用等级
        require(fee < 1000000);    // 费用不能超过 100%（1e6 = 100%）
        
        // tick 间距上限为 16384，防止在计算下一个已初始化的 tick 时溢出
        // 16384 个 tick 代表了超过 5 倍的价格变化（按 1 bips 计算）
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(feeAmountTickSpacing[fee] == 0);    // 确保该费用等级尚未启用

        // 设置新的费用等级和对应的 tick 间距
        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeAmountEnabled(fee, tickSpacing);    // 触发费用等级启用事件
    }
}
