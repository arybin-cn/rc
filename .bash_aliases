# FTP
alias ftp='lftp'

# Github
alias git='hub'

# Backup/Restore files to/from remote server
function BackupFiles(){
  rsync $@ xmu:~/BACKUP/ -Pv
}
function RestoreFiles(){
  rsync xmu:~/BACKUP/$@ . -Pv
}
alias bk=BackupFiles
alias rs=RestoreFiles

alias cdd='cd ~/Desktop'
alias cdp='cd ~/Projects'

# MRU files
ARB_MRU_FILES="$HOME/.*history $HOME/.viminfo $HOME/.swp $HOME/.xsession-errors*"
function ClearMruFiles(){
  for vmsdFile in $HOME/VMware/**/*.vmsd
  do
    sed -i "/^snapshot.lastUID/d" $vmsdFile
    sed -i "/^snapshot.mru/d" $vmsdFile
  done
  rm -rf $ARB_MRU_FILES 2>/dev/null
  history -c && exit
}
alias q=ClearMruFiles

# Proxy
PROXY_VARS="http_proxy https_proxy HTTP_PROXY HTTPS_PROXY"
function toggleProxy(){
  [ $http_proxy ] && proxy_tmp="" || proxy_tmp="http://127.0.0.1:1080"
  for proxy_var in $PROXY_VARS; do export $proxy_var=$proxy_tmp;done
  [ $http_proxy ] && operation_tmp="setted" || operation_tmp="cleared"
  echo "Proxies $operation_tmp."
  unset proxy_tmp operation_tmp
}
alias tp=toggleProxy

# Gem arb-dict
alias d='arb-dict'
