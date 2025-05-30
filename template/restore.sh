#!/usr/bin/env bash

# restore.sh 传参 a 自动还原 README.md 记录的文件，当本地与远程记录文件一样时不还原； 传参 f 不管本地记录文件，强制还原成备份库里 README.md 记录的文件； 传参 dashboard-***.tar.gz 还原成备份库里的该文件；不带参数则要求选择备份库里的文件名

GH_PROXY=
GH_PAT=
GH_BACKUP_USER=
GH_REPO=
SYSTEM=
WORK_DIR=
TEMP_DIR=/tmp/restore_temp
NO_ACTION_FLAG=/tmp/flag
IS_DOCKER=

########

# version: 2025.04.18

trap "rm -rf $TEMP_DIR; echo -e '\n' ;exit" INT QUIT TERM EXIT

mkdir -p $TEMP_DIR

warning() { echo -e "\033[31m\033[01m$*\033[0m"; }  # 红色
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

cmd_systemctl() {
  local ENABLE_DISABLE=$1
  if [ "$ENABLE_DISABLE" = 'enable' ]; then
    if [ "$SYSTEM" = 'Alpine' ]; then
      local TRY=5
      until [ $(systemctl is-active nezha-dashboard) = 'active' ]; do
        systemctl stop nezha-dashboard; sleep 1
        systemctl start nezha-dashboard
        ((TRY--))
        [ "$TRY" = 0 ] && break
      done
      cat > /etc/local.d/nezha-dashboard.start << ABC
#!/usr/bin/env bash

systemctl start nezha-dashboard
ABC
      chmod +x /etc/local.d/nezha-dashboard.start
      rc-update add local >/dev/null 2>&1
    else
      systemctl enable --now nezha-dashboard
    fi

  elif [ "$ENABLE_DISABLE" = 'disable' ]; then
    if [ "$SYSTEM" = 'Alpine' ]; then
      systemctl stop nezha-dashboard
      rm -f /etc/local.d/nezha-dashboard.start
    else
      systemctl disable --now nezha-dashboard
    fi
  fi
}

# 在本地有不备份标志文件时，不执行备份操作，等待10分钟。触发该标志场景：1. README.md 文件内容包含关键词 backup，2. backup.sh 脚本被手动执行完成后保持 9 分钟。
if [ -e $NO_ACTION_FLAG* ]; then
  FLAG_STATUS=$(ls $NO_ACTION_FLAG*)
  WAIT_MINUTE=9
  if [ "${FLAG_STATUS: -1}" != "$WAIT_MINUTE" ]; then
    mv -f $FLAG_STATUS $NO_ACTION_FLAG$((${FLAG_STATUS: -1} + 1))
    error "\n The script is not executed, please wait for $(( WAIT_MINUTE - ${FLAG_STATUS: -1} )) minutes. \n"
  else
    rm -f ${NO_ACTION_FLAG}*
  fi
fi

# 获取 Github 上的 README.md 文件内容
# ONLINE="$(wget -qO- --header="Authorization: token $GH_PAT" ${GH_PROXY}https://raw.githubusercontent.com/$GH_BACKUP_USER/$GH_REPO/main/README.md | sed "/^$/d" | head -n 1)"
ONLINE="$(curl -sSL --header "Authorization: token $GH_PAT" ${GH_PROXY}https://raw.githubusercontent.com/$GH_BACKUP_USER/$GH_REPO/main/README.md | sed "/^$/d" | head -n 1)"

# 若用户在 Github 的 README.md 里改了内容包含关键词 backup，则触发实时备份；为解决 Github cdn 导致获取文件内容来回跳的问题，设置自锁并检测到备份文件后延时3分钟断开（3次 运行 restore.sh 的时间)
if [ -z "$ONLINE" ]; then
  error "\n Failed to connect to Github or README.md is empty! \n"
elif grep -qi 'backup' <<< "$ONLINE"; then
  [ ! -e ${NO_ACTION_FLAG}* ] && { $WORK_DIR/backup.sh; exit 0; }
fi

# 根据传参标志作相应的处理
if [ "$1" = a ]; then
  [ "$ONLINE" = "$(cat $WORK_DIR/dbfile)" ] && exit
  [[ "$ONLINE" =~ tar\.gz$ && "$ONLINE" != "$(cat $WORK_DIR/dbfile)" ]] && FILE="$ONLINE" || exit
elif [ "$1" = f ]; then
  [[ "$ONLINE" =~ tar\.gz$ ]] && FILE="$ONLINE" || exit
elif [[ "$1" =~ tar\.gz$ ]]; then
  [[ "$FILE" =~ http.*/.*tar.gz ]] && FILE=$(awk -F '/' '{print $NF}' <<< $FILE) || FILE="$1"
elif [ -z "$1" ]; then
  # BACKUP_FILE_LIST=($(wget -qO- --header="Authorization: token $GH_PAT" https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO/contents/ | awk -F '"' '/"path".*tar.gz/{print $4}' | sort -r))
  BACKUP_FILE_LIST=($(curl -sSL --header "Authorization: token $GH_PAT" https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO/contents/ | awk -F '"' '/"path".*tar.gz/{print $4}' | sort -r))
  until [[ "$CHOOSE" =~ ^[1-${#BACKUP_FILE_LIST[@]}]$ ]]; do
    for i in ${!BACKUP_FILE_LIST[@]}; do echo " $[i+1]. ${BACKUP_FILE_LIST[i]} "; done
    echo ""
    [ -z "$FILE" ] && read -rp " Please choose the backup file [1-${#BACKUP_FILE_LIST[@]}]: " CHOOSE
    [[ ! "$CHOOSE" =~ ^[1-${#BACKUP_FILE_LIST[@]}]$ ]] && echo -e "\n Error input!" && sleep 1
    ((j++)) && [ $j -ge 5 ] && error "\n The choose has failed more than 5 times and the script exits. \n"
  done
  FILE=${BACKUP_FILE_LIST[$((CHOOSE-1))]}
fi

DOWNLOAD_URL=https://raw.githubusercontent.com/$GH_BACKUP_USER/$GH_REPO/main/$FILE
# wget --header="Authorization: token $GH_PAT" --header='Accept: application/vnd.github.v3.raw' -O $TEMP_DIR/backup.tar.gz ${GH_PROXY}${DOWNLOAD_URL}
curl -sSL --header "Authorization: token $GH_PAT" --header "Accept: application/vnd.github.v3.raw" -o "$TEMP_DIR/backup.tar.gz" "${GH_PROXY}${DOWNLOAD_URL}"

if [ -e $TEMP_DIR/backup.tar.gz ]; then
  if [ "$IS_DOCKER" = 1 ]; then
    hint "\n$(supervisorctl stop agent nezha grpcproxy)\n"
  else
    hint "\n Stop Nezha-dashboard \n" && cmd_systemctl disable
  fi

  # 解压缩备份文件到正式的工作文件夹
  rm -rf ${WORK_DIR}/data/*
  tar -xzvf $TEMP_DIR/backup.tar.gz -C ${WORK_DIR}
  rm -rf ${TEMP_DIR}

  # 在本地记录还原文件名
  echo "$ONLINE" > $WORK_DIR/dbfile
  if [ "$IS_DOCKER" = 1 ]; then
    hint "\n$(supervisorctl start agent nezha grpcproxy)\n"
  else
    hint "\n Start Nezha-dashboard \n" && cmd_systemctl enable >/dev/null 2>&1
  fi
  sleep 3
else
  warning "\n Failed to download backup file! \n"
fi

if [ "$IS_DOCKER" = 1 ]; then
  [ $(supervisorctl status all | grep -c "RUNNING") = $(grep -c '\[program:.*\]' /etc/supervisor/conf.d/damon.conf) ] && info "\n All programs started! \n" || error "\n Failed to start program! \n"
else
  [ "$(systemctl is-active nezha-dashboard)" = 'active' ] && info "\n Nezha dashboard started! \n" || error "\n Failed to start Nezha dashboard! \n"
fi
