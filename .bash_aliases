# ScreenFetch
alias sf='screenfetch'

# FTP
alias ftp='lftp'

# Github
alias git='hub'

# Backup/Restore files to/from remote server
function BackupFiles(){
  rsync $@ arybin.xyz:~/BACKUP/ -Pv
}
function RestoreFiles(){
  rsync arybin.xyz:~/BACKUP/$@ . -Pv
}
alias bk=BackupFiles
alias rs=RestoreFiles

alias cdd='cd ~/Desktop'

# Temp files
FILES_TMP="$HOME/.*history $HOME/.viminfo $HOME/.swp $HOME/.xsession-errors*"
alias q='rm -rf $FILES_TMP 2>/dev/null;history -c && exit'

# Lantern
PROXY_VARS="http_proxy https_proxy HTTP_PROXY HTTPS_PROXY"
function toggleLantern(){
  [ $http_proxy ] && proxy_tmp="" || proxy_tmp="http://127.0.0.1:19731"
  for proxy_var in $PROXY_VARS; do export $proxy_var=$proxy_tmp;done
  [ $http_proxy ] && operation_tmp="setted" || operation_tmp="cleared"
  echo "Proxies $operation_tmp."
  unset proxy_tmp operation_tmp
}
alias tl=toggleLantern

# Gem arb-dict
alias d='arb-dict'
