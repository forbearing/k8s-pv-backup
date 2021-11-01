#!/usr/bin/env bash

# how to recovery data: restic restore + rsync
#   kubectl -n [NAMESPACE] scale jenkins --replicas 0
#   mkdir /recovery
#   restic snapshots --tag jenkins --path /jennkins-home            # Get the latest snapshots
#   restic restore 7a8bf481 --target /recovery
#   rsync -avzH --delete /recovery/jenkins-home/ /jenkins-home/
#   kubectl -n [NAMESPACE] scale jenkins --replicas 1

EXIT_SUCCESS=0
EXIT_FAILURE=1
RETURN_SUCCESS=0
RETURN_FAILURE=1

trap "echo Interrupt by User; exit ${EXIT_SUCCESS}" INT


function _send_email { :; }
function _wait_restic_lock {
    if [[ -z ${RESTIC_TIMEOUT} ]]; then
        RESTIC_TIMEOUT=10
    fi
    while true; do
        find ${RESTIC_REPOSITORY}/locks -type f -cmin +${RESTIC_TIMEOUT} | xargs rm -rf
        if [[ $(ls ${RESTIC_REPOSITORY}/locks | wc -l) -eq 0 ]]; then
            break; fi
        sleep 1
    done
}

function restic_init {
    if [[ -z ${RESTIC_PASSWORD} ]]; then
        echo "Not set RESTIC_PASSWORD variable, exit..."
        exit ${EXIT_FAILURE}; fi
    if [[ -z ${RESTIC_REPOSITORY} ]]; then
        echo "Not set RESTIC_REPOSITORY variable, exit...";  fi
    if [[ ! -d ${RESTIC_REPOSITORY} ]]; then
        echo "${RESTIC_REPOSITORY} not directory or not exist, exit..."
        exit ${EXIT_FAILURE}; fi

    echo "Restic Init started..."
    local count=1
    while true; do
        _wait_restic_lock && restic list locks > /dev/null
        local list_lock_rc=$?
        if [[ ${list_lock_rc} -eq 0 ]]; then
            echo "Restic Repository Already exists."
            exit ${EXIT_SUCCESS}; fi
        if [[ ${count} -ge 6 ]]; then break; fi
        sleep 1
        restic unlock
        (( count++ ))
    done

    # 检查发现很可能没有 restic repository，就 restic init
    local count=1
    while true; do
        _wait_restic_lock && restic init
        local init_rc=$?
        if [[ ${init_rc} -eq 0 ]]; then
            echo "Restic Init Successful."
            exit ${EXIT_SUCCESS}; fi
        if [[ ${count} -ge 3 ]]; then break; fi
        sleep 1
        restic unlock
        (( count++ ))
    done
    echo "Restic Init Failed with Status: ${init_rc}."
    restic unlock
    exit ${EXIT_FAILURE}
}

function start_backup {
    local backup_from
    backup_from=$1

    local begin_backup_time=$(date +%s)       # begin backup time
    echo -e "\n\n========== Start Backup ${backup_from} at $(date +"%Y-%m-%d %H:%M:%S")\n"

    # restic backup, try 3 times
    local count=1
    echo "Restic Backup started..."
    local _begin=$(date +%s)
    while true; do
        _wait_restic_lock && restic backup ${backup_from} --tag ${RESTIC_TAG} > /dev/null
        local backup_rc=$?
        if [[ ${backup_rc} -eq 0 ]]; then # 备份成功退出循环
            break; fi
        if [[ ${count} -ge 3 ]]; then # 重试3次后还失败也退出循环
            break; fi
        restic unlock
        sleep 5; 
        (( count++ ))
    done
    local _end="$(date +%s)"
    if [[ ${backup_rc} -eq 0 ]]; then
        echo "Restic Backup Successful, it took $(( _end - _begin )) seconds"
    else
        echo "Restic Backup Failed with Status: ${backup_rc}."
        restic unlock
    fi

    # restic check
    echo "Restic Check started..."
    local _begin=$(date +%s)
    _wait_restic_lock && restic check > /dev/null
    local check_rc=$?
    local _end="$(date +%s)"
    if [[ ${check_rc} -eq 0 ]];then
        echo "Restic Check Successful, it took $(( _end - _begin )) seconds"
    else
        echo "Restic Check Failed with Status: ${check_rc}."
        restic unlock > /dev/null
    fi

    # restic forget --prune
    echo "Restic Forget started..."
    local _begin=$(date +%s)
    local restic_forget_args="--tag ${RESTIC_TAG} --path ${backup_from} --keep-last ${RESTIC_SNAPSHOT_COUNT}"
    _wait_restic_lock && restic forget --prune ${restic_forget_args} > /dev/null
    local forget_rc=$?
    local _end="$(date +%s)"
    if [[ ${forget_rc} -eq 0 ]]; then
        echo "Restic Forget Successful, it took $(( _end - _begin )) seconds"
    else
        echo "Restic Forget Failed with Status: ${forget_rc}."
        restic unlock > /dev/null
    fi

    # restic snapshots, list all snapshots
    echo "List All Snapshots"
    restic snapshots --tag ${RESTIC_TAG} --path ${backup_from}
    local snapshot_rc=$?
    if [[ ${snapshot_rc} -eq 0 ]]; then
        echo "Restic Snapshots Successful."
    else
        echo "Restic Snapshots Failed with Status: ${snapshot_rc}"
        restic unlock
    fi

    local end_backup_time=$(date +%s)         # end backup time
    echo -e "\n========== Finished Backup ${backup_from} at $(date +"%Y-%m-%d %H:%M:%H"), after $((end_backup_time - begin_backup_time)) seconds\n\n"
}


function start_prune {
    local backup_from
    backup_from=$1

    local begin_backup_time=$(date +%s)       # begin backup time
    echo -e "\n\n========== Start Prune ${backup_from} at $(date +"%Y-%m-%d %H:%M:%S")\n"

    # restic check
    echo "Restic Check started..."
    local _begin=$(date +%s)
    _wait_restic_lock && restic check > /dev/null
    local check_rc=$?
    local _end="$(date +%s)"
    if [[ ${check_rc} -eq 0 ]];then
        echo "Restic Check Successful, it took $(( _end - _begin )) seconds"
    else
        echo "Restic Check Failed with Status: ${check_rc}."
        restic unlock > /dev/null
    fi

    # restic forget --prune
    echo "Restic Forget started..."
    local _begin=$(date +%s)
    local restic_forget_args="--tag ${RESTIC_TAG} --path ${backup_from} --keep-last ${RESTIC_SNAPSHOT_COUNT}"
    _wait_restic_lock && restic forget --prune ${restic_forget_args} > /dev/null
    local forget_rc=$?
    local _end="$(date +%s)"
    if [[ ${forget_rc} -eq 0 ]]; then
        echo "Restic Forget Successful, it took $(( _end - _begin )) seconds"
    else
        echo "Restic Forget Failed with Status: ${forget_rc}."
        restic unlock > /dev/null
    fi

    local end_backup_time=$(date +%s)         # end backup time
    echo -e "\n========== Finished Prune ${backup_from} at $(date +"%Y-%m-%d %H:%M:%H"), after $((end_backup_time - begin_backup_time)) seconds\n\n"
}


function start_clean {
    local count=1
    while true; do
        kill -INT $(pgrep restic) &> /dev/null
        if [[ ${count} -ge 6 ]]; then
            break; fi
        sleep 1
        restic unlock
        (( count++ ))
    done
    kill -KILL $(pgrep restic) &> /dev/null
    restic unlock
    exit $EXIT_SUCCESS
}



# 判断变量
#   1. BACKUP_FROM              # 从哪里开始备份
#   2. RESTIC_REPOSITORY        # restic repository 路径，即备份到哪里去
#   3. RESTIC_PASSWORD          # restic 的密码
#   4. RESTIC_TAG               # resstic 给备份打标签
#   5. RESTIC_SNAPSHOT_COUNT    # restic 增量备份保留的个数
function check_variable {
    BACKUP_FROM=( ${BACKUP_FROM} )
    if [[ "${#BACKUP_FROM[*]}" -eq 0 ]]; then       # 数组为空，直接退出脚本
        echo "Not set the BACKUP_FROM variable, exit..."
        exit $EXIT_FAILURE; fi
    for path in "${BACKUP_FROM[@]}"; do             # 备份对象不存在，直接退出脚本
        if [[ ! -e "${path}" ]]; then
            echo "${path} no exist, exit..."
            exit $EXIT_FAILURE; fi
    done

    if [[ -z "${RESTIC_REPOSITORY}" ]]; then
        echo "Not set the RESTIC_REPOSITORY variable, exit..."
        exit $EXIT_FAILURE; fi
    if [[ ! -d "${RESTIC_REPOSITORY}" ]]; then
        echo "${RESTIC_REPOSITORY} not directory or not exist, exit..."
        exit $EXIT_FAILURE; fi

    if [[ -z "${RESTIC_PASSWORD}" ]]; then
        echo "restic password not set, exit..."
        exit $EXIT_FAILURE; fi
    if [[ -z "${RESTIC_TAG}" ]]; then
        RESTIC_TAG="default"; fi
    if [[ -z "${RESTIC_SNAPSHOT_COUNT}" ]]; then
        RESTIC_SNAPSHOT_COUNT=10; fi

    echo "BACKUP_FROM:              ${BACKUP_FROM[*]}"
    echo "RESTIC_REPOSITORY:        ${RESTIC_REPOSITORY}"
    echo "RESTIC_TAG:               ${RESTIC_TAG}"
    echo "RESTIC_SNAPSHOT_COUNT:    ${RESTIC_SNAPSHOT_COUNT}"
}

case "${1}" in 
backup)
    check_variable
    for path in "${BACKUP_FROM[@]}"; do
        start_backup ${path}
    done ;;
prune)
    check_variable
    for path in "${BACKUP_FROM[@]}"; do
        start_prune ${path}
    done ;;
clean)
    start_clean ;;
init)
    restic_init ;;
*)
    echo "not support option $1"
    exit $EXIT_FAILURE ;;
esac
