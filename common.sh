cleanup_knownhosts () {
  case "$OSTYPE" in
    darwin*|bsd*)
      sed_no_backup=( -i "''" )
      ;; 
    *)
      sed_no_backup=( -i )
      ;;
  esac

  sed ${sed_no_backup[@]} "s/$1.*//" ~/.ssh/known_hosts
  sed ${sed_no_backup[@]} "/^$/d" ~/.ssh/known_hosts
  sed ${sed_no_backup[@]} "/# ^$/d" ~/.ssh/known_hosts
}

wait_for_ssh () {
  echo "Waiting for SSH to become available..."
  if [ -z $2 ]; then
    while ! nc -z $1 22; do
        echo "Failed to connect to $1. Retrying in 5 seconds..."
        sleep 5
    done
  else
    set +e
    while true; do
      ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' -o 'ConnectTimeout=5' "$2@$1" uname -a
      if [ $? -eq 0 ]; then
        break
      else
        echo "Failed to connect to $1. Retrying in 5 seconds..."
        sleep 5
      fi
    done
    set -e
  fi
}

prepare_keystore () {
  op account get --account my &>/dev/null
  if [ $? -ne 0 ]; then
      eval $(op signin --account my)
  fi
}

get_private_key () {
  echo "$(op read "op://Private/$1/private key?ssh-format=openssh")"
}

get_public_key () {
  echo "$(op read "op://Private/$1/public key")"
}
