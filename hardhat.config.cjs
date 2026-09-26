require('@nomicfoundation/hardhat-ethers');

const {subtask}=require('hardhat/config');
const {TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD}=require('hardhat/builtin-tasks/task-names');

subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD).setAction(async({solcVersion},hre,runSuper)=>{
  if(solcVersion==='0.8.37'){
    const solc=require('solc');
    return{compilerPath:require.resolve('solc/soljson.js'),isSolcJs:true,version:'0.8.37',longVersion:solc.version()};
  }
  return runSuper();
});

module.exports={
  solidity:{version:'0.8.37',settings:{optimizer:{enabled:true,runs:500},evmVersion:'paris'}},
  paths:{sources:'./contracts',tests:'./test',cache:'./.cache',artifacts:'./artifacts'},
  networks:{hardhat:{chainId:31337}}
};
