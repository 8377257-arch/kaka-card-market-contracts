import{mkdirSync}from'node:fs';
import{spawn}from'node:child_process';
import{dirname,resolve}from'node:path';
import{fileURLToPath}from'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..'),appData=resolve(root,'.hardhat-appdata'),localAppData=resolve(root,'.hardhat-localappdata');
mkdirSync(appData,{recursive:true});mkdirSync(localAppData,{recursive:true});
const cli=resolve(root,'node_modules/hardhat/internal/cli/bootstrap.js'),child=spawn(process.execPath,[cli,...process.argv.slice(2),'--config',resolve(root,'hardhat.config.cjs')],{cwd:root,stdio:'inherit',env:{...process.env,APPDATA:appData,LOCALAPPDATA:localAppData,HARDHAT_DISABLE_TELEMETRY_PROMPT:'true'}});
child.on('exit',(code,signal)=>process.exit(signal?1:code??1));
