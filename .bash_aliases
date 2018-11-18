alias cdp='cd ~/Projects'
alias cdpp='cd /projects'
alias cdd='cd ~/Desktop'

# ScreenFetch
alias sf='screenfetch'

# FTP
alias ftp='lftp'

# SSHD
function sshd(){
  if [ "$(sudo service ssh status | grep not)" ]; then
    sshd_action="start"
  else
    sshd_action="stop"
  fi
  sudo service ssh $sshd_action
  unset sshd_action
}

# Temp files
FILES_TMP="$HOME/.*history $HOME/.viminfo $HOME/.swp $HOME/.xsession-errors*"
alias q='rm -rf $FILES_TMP 2>/dev/null;history -c && exit'

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
