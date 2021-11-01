#!/usr/bin/env bash

old_config_dir_path="/opt/k8s-pv-backup/config"
config_dir_path=/tmp/$(basename ${old_config_dir_path})
cache_dir_path="/opt/k8s-pv-backup/data/cache"
script_dir_path="/opt/k8s-pv-backup/script"
data_dir_path="/opt/k8s-pv-backup/data"
# old_config_dir_path="test/config"
# config_dir_path=/tmp/$(basename ${old_config_dir_path})
# cache_dir_path="test/data/cache"
mkdir -p ${config_dir_path}
mkdir -p ${cache_dir_path}

function copy_file {
    local file_list
    mkdir -p ${config_dir_path}
    rm -rf ${config_dir_path}/*
    mapfile file_list < <(find ${old_config_dir_path} -type f ! -iname global ! -iname '.*' -exec basename {} \;)
    for file in "${file_list[@]}"; do
        cat ${old_config_dir_path}/${file} > ${config_dir_path}/${file}
    done
}




# 1. 每隔一段时间就记录一次所有配置文件的 md5 值到 cache 文件中
# 2. 只保留两次所有配置文件的 md5 值记录
# 3. md5 值记录文件被读取成 shell dict
# 4. 计算 cache 文件的 md5 值，如果 md5 值不同，则是配置文件发生了修改
function check_file {
    local file_list

    # 1. 每隔指定时间就记录一次所有配置文件的 md5 值到 cache 文件中
    while true; do
        find "${config_dir_path}" -type f ! -name global ! -name '.*' -exec md5sum {} \; | \
            sort -k 2 | awk '{printf "%s  %s\n",$2,$1}' > ${cache_dir_path}/$(date +%s)
        mapfile file_list < <(ls -t ${cache_dir_path})
        if [[ "${#file_list[@]}" -ge 2 ]]; then break; fi
    done

    # 2. 只保留两次所有配置文件的 md5 值记录
    file_num=2
    for (( count=${file_num}; count<"${#file_list[@]}"; count++ )); do
        rm -rf ${cache_dir_path}/${file_list[count]}
    done
    mapfile file_list < <(ls -t ${cache_dir_path})

    new_file=${file_list[0]}
    old_file=${file_list[1]}
    # declare -p file_list
    # echo "${file_list[@]}";
    # echo -e "new_file: ${new_file}"
    # echo -e "old_file: ${old_file}"


    # 3. md5 值记录文件被读取成 shell dict
    # declare -A new_file_dict old_file_dict
    while read -r key value; do
        new_file_dict[${key}]=${value}
    done < ${cache_dir_path}/${new_file}
    while read -r key value; do
        old_file_dict[${key}]=${value}
    done < ${cache_dir_path}/${old_file}

    # 4. 计算 cache 文件的 md5 值，如果 md5 值不同，则是配置文件发生了修改
    new_file_md5=$(md5sum ${cache_dir_path}/${new_file} | awk '{print $1}')
    old_file_md5=$(md5sum ${cache_dir_path}/${old_file} | awk '{print $1}')
}


function add_backup_target {
    local file
    echo "===== [$(date "+%Y-%m-%d %H:%M:%S")] add backup target: ====="
    for old_key in "${!old_file_dict[@]}"; do
        unset new_file_dict["$old_key"]
    done
    for file in "${!new_file_dict[@]}"; do
        basename "${file}"
    done
    bash ${script_dir_path}/k8s-pv-backup.sh
}
function delete_backup_target {
    local file
    echo "===== [$(date "+%Y-%m-%d %H:%M:%S")] delete backup target: ====="
    for new_key in "${!new_file_dict[@]}"; do
        unset old_file_dict["$new_key"]
    done
    for file in "${!old_file_dict[@]}"; do
        basename "${file}"
    done
    for file in "${!old_file_dict[@]}"; do
        kubectl delete -f ${data_dir_path}/$(basename "${file}")
    done

}
function modified_backup_target {
    echo "===== [$(date "+%Y-%m-%d %H:%M:%S")] modified backup target: ====="
    for key in "${!new_file_dict[@]}"; do
        if [[ ${new_file_dict["$key"]} != ${old_file_dict["$key"]} ]]; then
            basename "${key}"
        fi
    done
    for key in "${!new_file_dict[@]}"; do
        if [[ ${new_file_dict["$key"]} != ${old_file_dict["$key"]} ]]; then
            bash ${script_dir_path}/k8s-pv-backup.sh
        fi
    done
}

bash ${script_dir_path}/k8s-pv-backup.sh
sleep_time=5
while true; do
    unset new_file_dict old_file_dict
    declare -A new_file_dict old_file_dict
    copy_file
    check_file

    if [[ ${new_file_md5} == ${old_file_md5} ]]; then
        # echo "===== [$(date "+%Y-%m-%d %H:%M:%S")] no change ====="
        sleep ${sleep_time}
        continue
    fi

    if [[ ${#new_file_dict[@]} -eq ${#old_file_dict[@]} ]]; then 
        modified_backup_target
    elif [[ ${#new_file_dict[@]} -gt ${#old_file_dict[@]} ]]; then
        add_backup_target
    elif [[ ${#new_file_dict[@]} -lt ${#old_file_dict[@]} ]]; then
        delete_backup_target
    fi
    sleep ${sleep_time}
done
