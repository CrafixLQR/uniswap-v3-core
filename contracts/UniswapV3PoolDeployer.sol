// SPDX-License-Identifier: BUSL-1.1

pragma solidity =0.7.6;

// 导入池子部署器的接口定义
import './interfaces/IUniswapV3PoolDeployer.sol';
// 导入交易池合约，这是将要被部署的合约
import './UniswapV3Pool.sol';

// UniswapV3PoolDeployer 合约，实现了 IUniswapV3PoolDeployer 接口
// 这个合约负责部署新的 UniswapV3Pool 实例
contract UniswapV3PoolDeployer is IUniswapV3PoolDeployer {
    // 定义参数结构体，用于存储池子的初始化参数
    struct Parameters {
        address factory;    // 工厂合约地址
        address token0;     // 第一个代币地址（排序后）
        address token1;     // 第二个代币地址（排序后）
        uint24 fee;        // 交易手续费率
        int24 tickSpacing; // tick 间距
    }

    // 声明一个公开的 parameters 变量，用于临时存储部署参数
    /// @inheritdoc IUniswapV3PoolDeployer
    Parameters public override parameters;

    /**
     * @dev 使用给定参数部署池子，临时设置参数后部署池子，然后清除参数
     * @param factory Uniswap V3 工厂合约地址
     * @param token0 池子中第一个代币的地址（按地址排序）
     * @param token1 池子中第二个代币的地址（按地址排序）
     * @param fee 池子中每次交换收取的费用，以 bip 的百分之一为单位
     * @param tickSpacing 可用 tick 之间的间距
     */
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address pool) {
        // 将部署参数存储到 parameters 变量中
        parameters = Parameters({
            factory: factory,
            token0: token0,
            token1: token1,
            fee: fee,
            tickSpacing: tickSpacing
        });

        // 部署新的 UniswapV3Pool 合约
        // salt 使用 token0、token1 和 fee 的哈希值，计算出合约地址 确保相同参数只能部署一次
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());

        // 部署完成后删除参数，释放存储空间
        delete parameters;
    }
}
