# Github
alias git='hub'

alias cdd='cd ~/Desktop'

# MRU files
ARB_MRU_FILES="$HOME/.*history $HOME/.viminfo $HOME/.swp $HOME/.xsession-errors*"
function clearMruFiles(){
  for vmsdFile in $HOME/VMware/**/*.vmsd
  do
    sed -i "/^snapshot.lastUID/d" $vmsdFile
    sed -i "/^snapshot.mru/d" $vmsdFile
  done
  rm -rf $ARB_MRU_FILES 2>/dev/null
  history -c && exit
}
alias q=clearMruFiles

# Proxy
PROXY_VARS="http_proxy https_proxy HTTP_PROXY HTTPS_PROXY"
function toggleProxy(){
  [ $http_proxy ] && proxy_tmp="" || proxy_tmp="http://mac:1087"
  for proxy_var in $PROXY_VARS; do export $proxy_var=$proxy_tmp;done
  [ $http_proxy ] && operation_tmp="setted" || operation_tmp="cleared"
  echo "Proxies $operation_tmp."
  unset proxy_tmp operation_tmp
}
alias tp=toggleProxy

# tmux print (history)
alias tmuxp="tmux capture-pane -pS -"
