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

# 设置时区，cronjob 备份依赖于时区，否则默认就是 UTC
export TZ="Asia/Shanghai"

# backup_target:            你要备份的对象是谁，比如：gitlab、jenkins、postgresql、mysql 等
# backup_policy:            你要备份的策略是哪种，支持：full，cumul、diff
# backup_from:              你要备份的对象的数据存放在哪里，就是你要备份的数据
# backup_to:                你要将备份对象的数据备份到哪里去
# full_backup_count:        你要保留几个全量备份
backup_target="${BACKUP_TARGET}"
backup_policy="${BACKUP_POLICY}"
backup_from="${BACKUP_FROM}"
backup_to="${BACKUP_TO}"
full_backup_count="${FULL_BACKUP_COUNT}"

# lock:                     简单的文件锁
# full_flag:                记录了最新的一个全量备份的路径
# full_backup_path:         全量备份的路径
# full_backup_snap_name:    全量备份的 snapshot 文件名，详解请查看 man tar 的 -g 选项
# full_backup_file_name:    全量备份的文件名
lock=""
full_flag=""
full_backup_path=""
full_backup_snap_name=""
full_backup_file_name=""

# cumul_backup_path:        累计增量备份的路径（默认等同于全量备份路径）
# cumul_backup_snap_name:   累计增量备份 snapshot 文件名，详解请查看 man tar 的 -g 选项
# cumul_backup_file_name:   累计增量备份文件名
cumul_backup_path=""
cumul_backup_snap_name=""
cumul_backup_file_name=""

# diff_backup_path:         差异增量备份的路径（默认等同于全量备份路径）
# diff_backup_snap_name:    差异增量备份 snapshot 文件名，详解请查看 man tar 的 -g 选项
# diff_backup_file_name:    差异增量备份文件名
diff_backup_path=""
diff_backup_snap_name=""
diff_backup_file_name=""


# 依赖于 flock 制作的文件锁，在 pod 中不生效.
LOCKFILE="/var/lock/backup-script"
LOCKFD=99
 
# PRIVATE
_lock()             { flock -$1 $LOCKFD; }
_no_more_locking()  { _lock u; _lock xn && rm -f $LOCKFILE; }
_prepare_locking()  { eval "exec $LOCKFD>\"$LOCKFILE\""; trap _no_more_locking EXIT; }
 
# ON START
_prepare_locking
 
# PUBLIC
exlock_now()        { _lock xn; }  # obtain an exclusive lock immediately or fail
exlock()            { _lock x; }   # obtain an exclusive lock
shlock()            { _lock s; }   # obtain a shared lock
unlock()            { _lock u; }   # drop a lock


# 1. 开始进行全量备份前加锁，目的是在全量备份的过程中，全量备份和增量备份不要同时进行
# 2. 创建全量备份目录
# 3. 记录全量备份目录的路径到 full_flag 中，增量备份依赖此文件来知道最近的一个全量备份是哪一个;
# 5. 开始备份
# 6. 根据 full_backup_count 的设置，删除旧的全量备份
# 7. 打印出目前所拥有的全量备份文件到标准输出
# 8. 解锁
function full_backup {
    echo -e "\n========== BEGIN ${BACKUP_TARGET^} Full Backup ===========\n"

    lock="${backup_to}"/"${backup_target}"/.lock
    full_flag="${backup_to}"/"${backup_target}"/.full
    full_backup_path="${backup_to}/${backup_target}/${backup_target}-$(date +%Y%m%d-%H%M)"
    full_backup_snap_name="${full_backup_path}/${backup_target}-full.sngz"
    full_backup_file_name="${full_backup_path}/${backup_target}-full.tgz"

    # 1. 开始进行全量备份前加锁，目的是在全量备份的过程中，全量备份和增量备份不要同时进行
    if [[ ! -d "${backup_to}"/"${backup_target}" ]]; then
        rm -rf "${backup_to}"/"${backup_target}"
        mkdir -p "${backup_to}"/"${backup_target}"; fi
    touch "${lock}"
    chattr +i "${lock}" &> /dev/null

    # 2. 创建全量备份目录
    if [[ ! -d ${full_backup_path} ]]; then
        rm -rf ${full_backup_path}
        mkdir -p ${full_backup_path}; fi

    # 3. 记录全量备份目录的路径到 full_flag 中
    touch "${full_flag}" &> /dev/null
    chattr -i "${full_flag}" &> /dev/null
    echo "${full_backup_path}" > "${full_flag}"
    chattr +i "${full_flag}" &> /dev/null

    # 如果 snapshot 文件存在，说明全量备份已经做过，直接跳过
    if [[ -e "${full_backup_snap_name}"  ]]; then
        echo "full backup already been done, skip..."
    else
        echo "full backup start..."
        # 5. 开始备份
        tar -pczg "${full_backup_snap_name}" -f "${full_backup_file_name}" "${backup_from}"
        chattr +i ${full_backup_snap_name} &> /dev/null
        echo "full backup finished"
    fi

    # 6. 根据 full_backup_count 的设置，删除旧的全量备份
    local array
    mapfile array < <(ls -td "${backup_to}"/"${backup_target}"/"${backup_target}"*)
    for (( count=${full_backup_count}; count<${#array[@]}; count++ )); do
        rm -rf ${array[count]}
    done

    # 7. 打印出目前所拥有的全量备份文件到标准输出
    echo -e "\n***** All Full Backup File *****"
    ls -lh --time-style=+%Y/%m/%d-%H:%M \
        "${backup_to}"/"${backup_target}"/"${backup_target}"*/*full*t* | \
        awk -F ' ' '{printf "%s  %s  %s\n", $5,$6,$7}'

    # 8. 解锁
    chattr -i "${lock}" &> /dev/null
    rm -rf  "${lock}"

    echo -e "\n========== END ${BACKUP_TARGET^} Full Backup =========="
}


# 1. 检测锁是否存在，如果锁存在，则说明全量备份正在进行，睡眠等待全量备份结束继续备份
# 2. 检测全量备份是否存在如果不存在，直接跳过备份
# 3. 开始备份
# 4. 列出所有的增量备份文件
function cumul_backup {
    echo -e "\n========== BEGIN ${BACKUP_TARGET^} Cumulative Incremental Backup ===========\n"

    sleep 5  # sleep 的目的是为了当 full backup 和 cumul backup 同时运行时, cumul backup 总是晚于 full backup 运行
    lock="${backup_to}"/"${backup_target}"/.lock # 简单的文件锁，cumul_backup 通过文件所来确认 full_backup 是否正在运行
    # 1. 检测锁是否存在，如果锁存在，则说明全量备份正在进行，睡眠等待全量备份结束继续备份
    while true; do
        if ls "${lock}" &> /dev/null; then 
            echo "full backup is in progress, waiting full backup finished..."
            sleep 10; 
        else break; fi
    done
    # cumul_backup 通过 full_backup_snap_name 来确认全量备份是否存在
    # cumul_backup 依赖 full_backup_snap_name 来比对时间戳而进行增量备份
    full_flag="${backup_to}"/"${backup_target}"/.full
    full_backup_path="$(cat ${full_flag} 2> /dev/null)"
    full_backup_snap_name="${full_backup_path}"/"${backup_target}"-"full.sngz"
    cumul_backup_path="${full_backup_path}"
    cumul_backup_snap_name="${cumul_backup_path}"/"${backup_target}"-"cumul.sngz"
    cumul_backup_file_name="${cumul_backup_path}"/"${backup_target}"-"cumul"-$(date +%d)-$(date +%H%M)".tgz"

    # 2. 检测全量备份是否存在如果不存在，直接跳过备份
    if [[ ! -e "${full_backup_snap_name}" ]]; then
        echo "full backup not exist, skip..."
    else
        # cumul_backup 和 diff_backup 不同, cumul_backup 每次备份都要拷贝，diff_backup 只需要拷贝一次
        cp "${full_backup_snap_name}" "${cumul_backup_snap_name}"

        # 3. 开始备份
        echo "cumulative incremental backup start..."
        tar -pczg "${cumul_backup_snap_name}" -f "${cumul_backup_file_name}" "${backup_from}"
        echo "cumulative incremental backup finished"

        # 4. 列出所有的增量备份文件
        echo -e "\n***** All Cumulative Incremental Backup File *****"
        ls -lh --time-style=+%Y/%m/%d-%H:%M \
            "${cumul_backup_path}"/"${backup_target}"-cumul-* | \
            awk -F ' ' '{printf "%s  %s  %s\n", $5,$6,$7}'
    fi
    echo -e "\n========== END ${BACKUP_TARGET^} Cumulative Incremental Backup =========="
}


# 1. 检测锁是否存在，如果锁存在，则说明全量备份正在进行，睡眠等待全量备份结束继续备份
# 2. 检测全量备份是否存在如果不存在，直接跳过备份
# 3. 开始备份
# 4. 列出所有的增量备份文件
function diff_backup {
    echo -e "\n========== BEGIN ${BACKUP_TARGET^} Differential Incremental Backup ===========\n"

    sleep 5  # sleep 的目的是为了当 full backup 和 diff backup 同时运行时, diff backup 总是晚于 full backup 运行
    lock="${backup_to}"/"${backup_target}"/.lock # 简单的文件锁，cumul_backup 通过文件所来确认 full_backup 是否正在运行
    # 1. 检测锁是否存在，如果锁存在，则说明全量备份正在进行，睡眠等待全量备份结束继续备份
    while true; do
        if ls "${lock}" &> /dev/null; then 
            echo "full backup is in progress, waiting full backup finished..."
            sleep 10; 
        else break; fi
    done

    # diff_backup 通过 full_backup_snap_name 来确认全量备份是否存在
    # diff_backup 依赖 full_backup_snap_name 来比对时间戳而进行增量备份
    full_flag="${backup_to}"/"${backup_target}"/.full
    full_backup_path="$(cat ${full_flag} 2> /dev/null)"
    full_backup_snap_name="${full_backup_path}"/"${backup_target}"-"full.sngz"
    diff_backup_path="${full_backup_path}"
    diff_backup_snap_name="${diff_backup_path}"/"${backup_target}"-"diff.sngz"
    diff_backup_file_name="${diff_backup_path}"/"${backup_target}"-"diff"-$(date +%d)-$(date +%H%M)".tgz"

    # 2. 检测全量备份是否存在如果不存在，直接跳过备份
    if [[ ! -e "${full_backup_snap_name}" ]]; then
        echo "full backup not exist, skip..."
    else
        # cumul_backup 和 diff_backup 不同, cumul_backup 每次备份都要拷贝，diff_backup 只需要拷贝一次
        if [[ ! -e "${diff_backup_snap_name}" ]]; then
            cp "${full_backup_snap_name}" "${diff_backup_snap_name}"; fi

        # 3. 开始备份
        echo "differential incremental backup start..."
        tar -pczg "${diff_backup_snap_name}" -f "${diff_backup_file_name}" "${backup_from}"
        echo "differential incremental backup finished"

        # 4. 列出所有的增量备份文件
        echo -e "\n***** All Differential Incremental Backup File *****"
        ls -lh --time-style=+%Y/%m/%d-%H:%M \
            "${diff_backup_path}"/"${backup_target}"-diff-* | \
            awk -F ' ' '{printf "%s  %s  %s\n", $5,$6,$7}'
    fi

    echo -e "\n========== END ${BACKUP_TARGET^} Differential Incremental Backup =========="
}


# 打印变量信息
echo -e "\n***** Backup ${backup_target^} Environment *****"
printf "backup_target:       %s\n" "${backup_target}"
printf "backup_policy:       %s\n" "${backup_policy}"
printf "backup_from:         %s\n" "${backup_from}"
printf "backup_to:           %s\n" "${backup_to}"
printf "full_backup_count:   %s\n" "${full_backup_count}"

# 如果备份对象所在的目录不存在，直接退出脚本
if [[ ! -d ${backup_from} ]]; then
    echo ${backup_from} directory not exist
    exit ${EXIT_FAILURE}; fi
# 如果备份对象的备份存储目录不存在，直接退出脚本
if [[ ! -d ${backup_to} ]]; then
    echo ${backup_to} directory not exist
    exit ${EXIT_FAILURE}; fi
# 如果要全量备份保留个数 <= 0，则直接退出脚本
if [[ ${full_backup_count} -le 0 ]]; then
    echo ${full_backup_count} must greater than 0
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
