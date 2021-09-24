#!/bin/bash
#
# ref:
#   https://snapshooter.com/learn/linux/incremental-tar
#   https://floatingoctothorpe.uk/2018/incremental-tar-backups.html
#   https://www.computernetworkingnotes.com/linux-tutorials/create-and-restore-incremental-backups-in-linux-with-tar.html
#
# Two kinds of Incremental Backups:
#   Cumulative Incremental:
#       This will backup all changes this the last Full backup.
#   Differential Incremental:
#       This will backup all changes since last backup - Full or Incremental.

EXIT_SUCCESS=0
EXIT_FAILURE=1
RETURN_SUCCESS=0
RETURN_FAILURE=1

export TZ="Asia/Shanghai"

backup_target="${BACKUP_TARGET}"
backup_policy="${BACKUP_POLICY}"
backup_from="${BACKUP_FROM}"
backup_to="${BACKUP_TO}"
full_backup_number="${FULL_BACKUP_NUMBER}"

full_backup_path="$(cat ${backup_to}/${backup_target}/full)"
full_backup_snap_name="${full_backup_path}"/"${backup_target}"-"full.sngz"
full_backup_file_name="${full_backup_path}"/"${backup_target}"-"full.tgz"
lock="${full_backup_path}"/lock

diff_backup_path="${full_backup_path}"
diff_backup_snap_name="${diff_backup_path}"/"${backup_target}"-"diff.sngz"
diff_backup_file_name="${diff_backup_path}"/"${backup_target}"-"diff"-$(date +%d)-$(date +%H%M)".tgz"

cumul_backup_path="${full_backup_path}"
cumul_backup_snap_name="${cumul_backup_path}"/"${backup_target}"-"cumul.sngz"
cumul_backup_file_name="${cumul_backup_path}"/"${backup_target}"-"cumul"-$(date +%d)-$(date +%H%M)".tgz"



function full_backup {
    echo "========== BEGIN ${BACKUP_TARGET^} Full Backup ==========="

    # 记录全量备份的目录名，累计增量备份和差异增量备份需要知道全备份的目录路径
    # full_backup_path:
    # full_backup_snap_name:
    # full_backup_file_name:
    # lock:
    #   如果是全量备份，这四个变量是自己根据当前的时间戳来生成的
    #   如果是增量备份，这四个变量是从 cat ${backup_to}/${backup_target}/full 中读取生成的
    #   ${backup_to}/${backup_target}/full 记录了当前最近的一个全量备份的名称
    full_backup_path="${backup_to}/${backup_target}/${backup_target}-$(date +%Y%m%d-%H%M)"
    full_backup_snap_name="${full_backup_path}/${backup_target}-full.sngz"
    full_backup_file_name="${full_backup_path}/${backup_target}-full.tgz"
    lock="${full_backup_path}"/lock
    local flag="${backup_to}"/"${backup_target}"/full

    # 创建全量备份的目录
    if [[ ! -d ${full_backup_path} ]]; then
        rm -rf ${full_backup_path}
        mkdir -p ${full_backup_path}; fi

    touch "${flag}"
    chattr -i "${flag}" &> /dev/null
    echo "${full_backup_path}" > "${flag}"
    chattr +i "${flag}" &> /dev/null

    # 如果 ${full_backup_snap_name} 存在，说明全量备份已经做过，直接跳过
    if [[ -e "${full_backup_snap_name}"  ]]; then
        echo "full backup already been done, skip..."
    else
        echo "full backup start..."
        # 加锁。在这里加锁的目的就是：在全量备份的时候，增量备份不要进行
        touch "${lock}"
        chattr +i "${lock}" &> /dev/null
        # 开始备份
        tar -pczg "${full_backup_snap_name}" -f "${full_backup_file_name}" "${backup_from}"
        chattr +i ${full_backup_snap_name} &> /dev/null
        # 解锁
        chattr -i "${lock}" &> /dev/null
        rm -rf  "${lock}"
        echo "full backup finished"
    fi

    # clean old full backup

    echo "========== END ${BACKUP_TARGET^} Full Backup =========="
}


# 1. 检测全量备份是否存在如果不存在，直接跳过备份
# 2. 检测锁是否存在，如果锁存在，则说明全量备份正在进行，睡眠等待全量备份结束继续备份
# 3. 开始备份
function diff_backup {
    echo "========== BEGIN ${BACKUP_TARGET^} Differential Incremental Backup ==========="

    # 1. 检测全量备份是否存在如果不存在，直接跳过备份
    if [[ ! -e "${full_backup_snap_name}" ]]; then
        echo "full backup not exist, skip..."
    else
        # 2. 检测锁是否存在，如果锁存在，则说明全量备份正在进行，睡眠等待全量备份结束继续备份
        while true; do
          if ls "${lock}" &> /dev/null; then 
              echo "full backup is in progress, waiting full backup finished..."
              sleep 10; 
          else break; fi
        done
        # 差异增量备份和累计增量备份不同，差异增量备份只拷贝一次，累计增量备份开始备份之前都要拷贝一次
        if [[ ! -e "${diff_backup_snap_name}" ]]; then
            cp "${full_backup_snap_name}" "${diff_backup_snap_name}"; fi
        # 3. 开始备份
        echo "differential incremental backup start..."
        tar -pczg "${diff_backup_snap_name}" -f "${diff_backup_file_name}" "${backup_from}"
        echo "differential incremental backup finished"
    fi

    echo "========== END ${BACKUP_TARGET^} Differential Incremental Backup =========="
}


# 1. 检测全量备份是否存在如果不存在，直接跳过备份
# 2. 检测锁是否存在，如果锁存在，则说明全量备份正在进行，睡眠等待全量备份结束继续备份
# 3. 开始备份
function cumul_backup {
    echo "========== BEGIN ${BACKUP_TARGET^} Cumulative Incremental Backup ==========="

    # 1. 检测全量备份是否存在如果不存在，直接跳过备份
    if [[ ! -e "${full_backup_snap_name}" ]]; then
        echo "full backup not exist, skip..."
    else
        # 2. 检测锁是否存在，如果锁存在，则说明全量备份正在进行，睡眠等待全量备份结束继续备份
        while true; do
          if ls "${lock}" &> /dev/null; then 
              echo "full backup is in progress, waiting full backup finished..."
              sleep 10; 
          else break; fi
        done
        # 差异增量备份和累计增量备份不同，差异增量备份只拷贝一次，累计增量备份开始备份之前都要拷贝一次
        cp "${full_backup_snap_name}" "${cumul_backup_snap_name}"
        # 3. 开始备份
        echo "cumulative incremental backup start..."
        tar -pczg "${cumul_backup_snap_name}" -f "${cumul_backup_file_name}" "${backup_from}"
        echo "cumulative incremental backup finished"
    fi
    echo "========== END ${BACKUP_TARGET^} Cumulative Incremental Backup =========="
}

printf "\nbackup_target: %-60s\n"       "${BACKUP_TARGET}"
printf "backup_policy: %-60s\n"         "${BACKUP_POLICY}"
printf "backup_from: %-60s\n"           "${backup_from}"
printf "backup_to: %-60s\n"             "${backup_to}"
printf "full_backup_number: %-60s\n"    "${full_backup_number}"

if [[ ! -d ${backup_from} ]]; then
    echo ${backup_from} directory not exist
    exit ${EXIT_FAILURE}; fi
if [[ ! -d ${backup_to} ]]; then
    echo ${backup_to} directory not exist
    exit ${EXIT_FAILURE}; fi

case ${backup_policy} in 
full)   # if backup_policy is "full", start full backup
    full_backup ;;
diff)   # if backup_policy is "diff", start differential incremental backup
    diff_backup ;;
cumul)  # if backup_policy is "cumul", start cumulative incremental backup
    cumul_backup ;;
*)
    echo "not support backup policy: ${backup_policy}"
    exit ${EXIT_FAILURE} ;;
esac
