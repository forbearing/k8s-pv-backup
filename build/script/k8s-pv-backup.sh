#!/usr/bin/env bash


EXIT_SUCCESS=0
EXIT_FAILURE=1
RETURN_SUCCESS=0
RETURN_FAILURE=1

# 一: 变量部分 ========================================================================#
# # k8s cluster name
# CLUSTER_NAME="cicd"

declare -a BACKUP_TARGET_PVC_LIST    # 资源对象的 pvc 列表
declare -A BACKUP_TARGET_LABEL_LIST  # 资源对象的 label 字典


# RESTIC_TAG=""                   # set by funtiion
# RESTIC_PASSWORD="restic"        # restic 密码
# RESTIC_SNAPSHOT_COUNT="10"      # restic 保留的 snapshot 个数
# RESTIC_REPOSITORY='/restic'     # restic repository 路径
# NFS_SERVER="10.240.1.21"
# NFS_PATH="/srv/nfs/restic-cicd"


K8S_PV_BACKUP_NAMESPACE="kube-backup"
K8S_PV_BACKUP_PATH="/opt/k8s-pv-backup"
K8S_PV_BACKUP_CONFIG_PATH="${K8S_PV_BACKUP_PATH}/config"
K8S_PV_BACKUP_RESTIC_PATH="${K8S_PV_BACKUP_PATH}/restic"

TEMPLATE_SRC_DIR="${K8S_PV_BACKUP_PATH}/template"
TEMPLATE_DST_DIR="${K8S_PV_BACKUP_PATH}/data"
TEMPLATE_RESTIC_INIT_FILE="template-job-restic-init.yaml"
TEMPLATE_BACKUP_FILE="template-cronjob-backup.yaml"
TEMPLATE_RECOVERY_FILE="template-deployment-recovery.yaml"
TEMPLATE_CONFIGMAP_FILE="template-configmap.yaml"
TEMPLATE_SECRET_FILE="template-secret.yaml"

if ! ls "${TEMPLATE_DST_DIR}/.flag" &> /dev/null; then
    rm -rf "${TEMPLATE_DST_DIR}"/* &> /dev/null
    rm -rf "${TEMPLATE_DST_DIR}"/.* &> /dev/null
    touch "${TEMPLATE_DST_DIR}"/.flag; fi

# check global variable:
#   K8S_PV_BACKUP_CONFIG_PATH
#   CLUSTER_NAME, RESTIC_PASSWORD, RESTIC_STORAGE
function check_global_variable {
    if [[ ! -d ${K8S_PV_BACKUP_CONFIG_PATH} ]]; then
        echo "directory ${K8S_PV_BACKUP_CONFIG_PATH} not exist, exit..."
        exit ${EXIT_FAILURE}; fi
    if [[ ! -f ${K8S_PV_BACKUP_CONFIG_PATH}/global ]]; then
        echo "config file ${K8S_PV_BACKUP_CONFIG_PATH}/global not exist, exit..."
        exit ${EXIT_FAILURE}; fi

    source ${K8S_PV_BACKUP_CONFIG_PATH}/global
    if [[ -z "${CLUSTER_NAME}" ]]; then
        echo "Not set CLUSTER_NAME variable, exit..."
        exit ${EXIT_FAILURE}; fi
    if [[ -z "${RESTIC_PASSWORD}"  ]]; then
        echo "Not set RESTIC_PASSWORD variable, exit..."
        exit ${EXIT_FAILURE}; fi
    if [[ -z "${RESTIC_STORAGE}" ]]; then
        echo "Not set RESTIC_STORAGE variable, exit..."; fi
    if [[ -z "${RESTIC_REPOSITORY}" ]]; then
        RESTIC_REPOSITORY="/restic"; fi
}

# check backup target variable
#   BACKUP_TARGET_NAME, BACKUP_TARGET_NAMESPACE
#   RESTIC_SNAPSHOT_COUNT, RESTIC_BACKUP_SCHEDULE
function check_backup_target_variable {
    BACKUP_TARGET_NAME="${1}"
    if [[ ! -f ${K8S_PV_BACKUP_CONFIG_PATH}/${BACKUP_TARGET_NAME} ]]; then
        echo "config file ${K8S_PV_BACKUP_CONFIG_PATH}/${BACKUP_TARGET_NAME} not exist, exit..."
        exit ${EXIT_FAILURE}; fi
    source "${K8S_PV_BACKUP_CONFIG_PATH}/${BACKUP_TARGET_NAME}"

    if [[ -z ${RESTIC_SNAPSHOT_COUNT} ]]; then
        RESTIC_SNAPSHOT_COUNT=10; fi
    if [[ -z "${RESTIC_BACKUP_SCHEDULE}" ]]; then
        echo "Not set RESTIC_BACKUP_SCHEDULE variable, exit..."
        exit ${EXIT_FAILURE}; fi
    if [[ -z "${RESTIC_BACKUP_IMAGE}" ]]; then
        RESTIC_BACKUP_IMAGE="registry.cn-shanghai.aliyuncs.com/hybfkuf/hybfkuf-backup:latest"; fi
}

# check restic storage variable
#   NFS_SERVER, NFS_PATH
function check_restic_storage_variable {
    BACKUP_TARGET_NAME="${1}"
    if [[ ! -f ${K8S_PV_BACKUP_CONFIG_PATH}/${BACKUP_TARGET_NAME} ]]; then
        echo "config file ${K8S_PV_BACKUP_CONFIG_PATH}/${BACKUP_TARGET_NAME} not exist, exit..."
        exit ${EXIT_FAILURE}; fi
    source "${K8S_PV_BACKUP_CONFIG_PATH}/${BACKUP_TARGET_NAME}"

    if [[ -z ${NFS_SERVER} ]]; then
        echo "Not set NFS_SERVER variable, exit..."
        exit ${EXIT_FAILURE}; fi
    if [[ -z ${NFS_PATH} ]]; then
        echo "Not set NFS_PATH variable, exit..."
        exit ${EXIT_FAILURE}; fi
}


# while getopts "n:r:h" opt; do
#     case ${opt} in
#     n) RESOURCE_NAMESPACE=${OPTARG} ;;
#     r) RESOURCE_NAME=${OPTARG} ;;
#     h) echo "$(basename $0) -n <namespace> -r <resource_name>"
#        exit $EXIT_SUCCESS;;
#     *) echo "Use \"$(basename $0) -h\" to see the usage"
#        exit $EXIT_FAILURE
#     esac
# done



# 二: 函数定义部分 ====================================================================#

# 私有函数: 被 get_backup_target_type 函数调用
# 获取 backup target type: deployment, statefulset, daemonset, pod
function _get_backup_target_type() {
    local backup_target_name=$1
    local backup_target_namespace=$2
    local count=1
    while true; do
        if kubectl -n ${backup_target_namespace} get deployment ${backup_target_name} &> /dev/null; then
            BACKUP_TARGET_NAMESPACE=${backup_target_namespace}
            BACKUP_TARGET_TYPE="deployment"
            get_target_type_flag="ture"
            break
        elif kubectl -n ${backup_target_namespace} get statefulset ${backup_target_name} &> /dev/null; then
            BACKUP_TARGET_NAMESPACE=${backup_target_namespace}
            BACKUP_TARGET_TYPE="statefulset"
            get_target_type_flag="ture"
            break
        elif kubectl -n ${backup_target_namespace} get daemonset ${backup_target_name} &> /dev/null; then
            BACKUP_TARGET_NAMESPACE=${backup_target_namespace}
            BACKUP_TARGET_TYPE="daemonset"
            get_target_type_flag="ture"
            break
        elif kubectl -n ${backup_target_namespace} get pod ${backup_target_name} &> /dev/null; then
            BACKUP_TARGET_NAMESPACE=${backup_target_namespace}
            BACKUP_TARGET_TYPE="pod"
            get_target_type_flag="ture"
            break; fi
        if [[ $count -ge 3 ]]; then 
            get_target_type_flag="false"
            break; fi     # 尝试三次，可能因为网络问题导致 get 失败
        (( count++ ))
    done
}

# 获取资源类型
function get_backup_target_type() {
    local backup_target_name=$1
    local backup_target_namespace=$2
    local backup_target_namespace_list
    local count=1

    # 如果设置了 backup_target_namespace 变量，就直接调用 _get_backup_target_type 函数
    # 如果获取到备份对象的类型，就成功退出函数，如果获取不到则继续
    if [[ -n ${backup_target_namespace} ]]; then
        _get_backup_target_type ${backup_target_name} ${backup_target_namespace}
        if [[ ${get_target_type_flag} == "true" ]]; then
            return ${RETURN_SUCCESS}; fi
    fi

    # 如果没有设置 backup_target_namespace 变量，先获取所有 namespace，再调用 _get_backup_target_type
    # 考虑网络不好的情况，重试 3 次获取 kubectl get namespace，3 次还获取不到所有的 namespace 退出脚本
    while true; do
        backup_target_namespace_list=$(kubectl get namespace -o jsonpath='{.items[*].metadata.name}')
        if [[ $? -eq 0 ]]; then break; else sleep 3; fi     # 获取到了 namespace 就退出循环，否则 sleep 后继续循环
        if [[ ${count} -ge 3 ]]; then                       # 尝试三次，可能是因为网络原因
            echo "Can not get backup_target_namespace. EXIT..."
            exit $EXIT_FAILURE; fi
        (( count++ ))
    done
    for item in ${backup_target_namespace_list[@]}; do
        _get_backup_target_type ${backup_target_name} ${item}
    done
}

function get_backup_target_pvc_and_labels {
    local backup_target_pvc_list
    local backup_target_label_list
    local label_array

    local backup_target_name=$1
    local backup_target_type=$2
    local backup_target_namespace=$3
    

    case ${backup_target_type} in
    deployment)
        # 1. 获取 deployment 挂载的 pvc
        backup_target_pvc_list=$(kubectl -n ${backup_target_namespace} get deployment ${backup_target_name} \
            -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}')
        BACKUP_TARGET_PVC_LIST=( ${backup_target_pvc_list[@]} )
        # 2. 获取 deployment 的 label
        backup_target_label_list=$(kubectl -n ${backup_target_namespace} get deployment ${backup_target_name} \
            -o jsonpath='{.spec.selector.matchLabels}' | jq . | grep -E -v '{|}|^$' | awk -F ':' '{print $1}')
        mapfile label_array < <(echo ${backup_target_label_list//\"})
        for key in ${label_array[@]}; do
            value=$(kubectl -n ${backup_target_namespace} get deployment ${backup_target_name} -o jsonpath='{.spec.selector.matchLabels}' | jq .${key})
            value=${value//\"}
            BACKUP_TARGET_LABEL_LIST[$key]=$value
        done; ;;
    statefulset)
        # 1. 获取 statefulset .spec.replicas 字段值
        local sts_replicas=$(kubectl -n ${backup_target_namespace} get statefulset ${backup_target_name} \
            -o jsonpath='{.spec.replicas}')
        # 2. 获取 statefulset 生成的 pvc
        backup_target_pvc_list=$(kubectl -n ${backup_target_namespace} get statefulset ${backup_target_name} \
            -o jsonpath='{.spec.volumeClaimTemplates[*].metadata.name}')
        for pvc in ${backup_target_pvc_list[@]}; do
            for (( count=0; count <$sts_replicas; count++ )); do
                BACKUP_TARGET_PVC_LIST+=( $pvc-$backup_target_name-$count )
            done
        done
        # 3. 获取 statefulset 的 label
        backup_target_label_list=$(kubectl -n ${backup_target_namespace} get statefulset ${backup_target_name} \
            -o jsonpath='{.spec.selector.matchLabels}' | jq . | grep -E -v '{|}|^$' | awk -F ':' '{print $1}')
        mapfile label_array < <(echo ${backup_target_label_list//\"})
        for key in ${label_array[@]}; do
            value=$(kubectl -n ${backup_target_namespace} get statefulset ${backup_target_name} -o jsonpath='{.spec.selector.matchLabels}' | jq .${key})
            value=${value//\"}
            BACKUP_TARGET_LABEL_LIST[$key]=$value
        done; ;;
    daemonset)
        # 1. 获取 daemonset 挂载的 pvc
        backup_target_pvc_list=$(kubectl -n ${backup_target_namespace} get daemonset ${backup_target_name} \
            -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}')
        BACKUP_TARGET_PVC_LIST=( ${backup_target_pvc_list[@]} )
        # 2. 获取 daemonset 的 labels
        backup_target_label_list=$(kubectl -n ${backup_target_namespace} get daemonset ${backup_target_name} \
            -o jsonpath='{.spec.selector.matchLabels}' | jq . | grep -E -v '{|}|^$' | awk -F ':' '{print $1}')
        mapfile label_array < <(echo ${backup_target_label_list//\"})
        for key in ${label_array[@]}; do
            value=$(kubectl -n ${backup_target_namespace} get daemonset ${backup_target_name} -o jsonpath='{.spec.selector.matchLabels}' | jq .${key})
            value=${value//\"}
            BACKUP_TARGET_LABEL_LIST[$key]=$value
        done; ;;
    pod)
        # 1. 获取 pod 的 挂载的 pvc
        backup_target_pvc_list=$(kubectl -n ${backup_target_namespace} get pod ${backup_target_name} \
            -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}')
        BACKUP_TARGET_PVC_LIST=( ${backup_target_pvc_list[@]} )
        # 2. 获取 pod 的 labels
        backup_target_label_list=$(kubectl -n ${backup_target_namespace} get pod ${backup_target_name} \
            -o jsonpath='{.metadata.labels}' | jq . | grep -E -v '{|}|^$' | awk -F ':' '{print $1}' )
        mapfile label_array < <(echo ${backup_target_label_list//\"})
        for key in ${label_array[@]}; do
            value=$(kubectl -n ${backup_target_namespace} get pod ${backup_target_name} -o jsonpath='{.metadata.labels}' | jq .${key})
            value=${value//\"}
            BACKUP_TARGET_LABEL_LIST[$key]=$value
        done; ;;
    esac
}

function template_common_handler {
    local backup_target_name
    local backup_target_type
    local backup_target_namespace

    local restic_password
    local restic_repository
    local restic_snapshot_count
    local restic_backup_schedule

    local restic_backup_name
    local restic_backup_schedule
    local restic_backup_image
    local restic_recovery_name
    local restic_backup_target_tag

    backup_target_name=${BACKUP_TARGET_NAME}
    backup_target_type=${BACKUP_TARGET_TYPE}
    backup_target_namespace=${BACKUP_TARGET_NAMESPACE}

    restic_password="${RESTIC_PASSWORD}"
    restic_repository="${RESTIC_REPOSITORY}"
    restic_snapshot_count="${RESTIC_SNAPSHOT_COUNT}"
    restic_backup_schedule="${RESTIC_BACKUP_SCHEDULE}"

    restic_backup_name="backup-restic-${BACKUP_TARGET_NAME}"
    restic_backup_schedule="${RESTIC_BACKUP_SCHEDULE}"
    restic_backup_image="${RESTIC_BACKUP_IMAGE}"
    restic_recovery_name="recovery-restic-${BACKUP_TARGET_NAME}"
    restic_backup_target_tag="${CLUSTER_NAME}-${BACKUP_TARGET_NAMESPACE}-${BACKUP_TARGET_NAME}"

    for file in \
        ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_BACKUP_FILE} \
        ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_RECOVERY_FILE} \
        ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_CONFIGMAP_FILE} \
        ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_SECRET_FILE}; do
        sed -i "s%#BACKUP_TARGET_NAME#%${backup_target_name}%g"              ${file}
        sed -i "s%#BACKUP_TARGET_NAMESPACE#%${backup_target_namespace}%g"    ${file}
        sed -i "s%#RESTIC_PASSWORD#%${restic_password}%g"                    ${file}
        sed -i "s%#RESTIC_REPOSITORY#%${restic_repository}%g"                ${file}
        sed -i "s%#RESTIC_BACKUP_NAME#%${restic_backup_name}%g"              ${file}
        sed -i "s%#RESTIC_SNAPSHOT_COUNT#%${restic_snapshot_count}%g"        ${file}
        sed -i "s%#RESTIC_BACKUP_SCHEDULE#%${restic_backup_schedule}%g"      ${file}
        sed -i "s%#RESTIC_BACKUP_IMAGE#%${restic_backup_image}%g"            ${file}
        sed -i "s%#RESTIC_RECOVERY_NAME#%${restic_recovery_name}%g"          ${file}
        sed -i "s%#RESTIC_BACKUP_TARGET_TAG#%${restic_backup_target_tag}%g"  ${file}
    done

}

function template_pvc_handler {
    local pvc_list
    local pvc_list_string
    declare -a pvc_list

    # TEMPLATE_BACKUP_FILE handler
    for pvc in "${BACKUP_TARGET_PVC_LIST[@]}"; do
        local vol_string1="          - name: ${pvc}\n"
        local vol_string2="            persistentVolumeClaim:\n"
        local vol_string3="              claimName: ${pvc}\n"
        local vol_string4="              readOnly: true"
        local volm_string1="            - name: ${pvc}\n"
        local volm_string2="              mountPath: /${pvc}"
        sed -i "/volumes:/a\\${vol_string1}${vol_string2}${vol_string3}${vol_string4}" \
            ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_BACKUP_FILE}
        sed -i "/volumeMounts:/a\\${volm_string1}${volm_string2}" \
            ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_BACKUP_FILE}
    done

    # TEMPLATE_RECOVERY_FILE handler
    for pvc in "${BACKUP_TARGET_PVC_LIST[@]}"; do
        local vol_string1="      - name: ${pvc}\n"
        local vol_string2="        persistentVolumeClaim:\n"
        local vol_string3="          claimName: ${pvc}\n"
        local vol_string4="          readOnly: false"
        local volm_string1="        - name: ${pvc}\n"
        local volm_string2="          mountPath: ${pvc}"
        # grep -A 40 -Rsi 'volumeMounts:' ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_RECOVERY_FILE}
        sed -i "/volumes:/a\\${vol_string1}${vol_string2}${vol_string3}${vol_string4}" \
            ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_RECOVERY_FILE}
        sed -i "/volumeMounts:/a\\${volm_string1}${volm_string2}" \
            ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_RECOVERY_FILE}
    done

    # TEMPLATE_CONFIGMAP_FILE handler
    for pvc in "${BACKUP_TARGET_PVC_LIST[@]}"; do
        pvc_list+=( /${pvc} ); done
    pvc_list_string="${pvc_list[@]}"
    sed -i "s%#BACKUP_TARGET_PVC_LIST#%${pvc_list_string}%g" \
        ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_CONFIGMAP_FILE}
}

function template_label_handler {
    # TEMPLATE_BACKUP_FILE handler
    for key in "${!BACKUP_TARGET_LABEL_LIST[@]}"; do
        value=${BACKUP_TARGET_LABEL_LIST[$key]}
        local l_string1="                  - key: ${key}\n"
        local l_string2="                    operator: In\n"
        local l_string3="                    values:\n"
        local l_string4="                    - ${value}"
        sed -i "/matchExpressions:/a\\${l_string1}${l_string2}${l_string3}${l_string4}" \
            ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_BACKUP_FILE}
    done

    # TEMPLATE_RECOVERY_FILE handler
    for key in "${!BACKUP_TARGET_LABEL_LIST[@]}"; do
        value=${BACKUP_TARGET_LABEL_LIST[$key]}
        local l_string1="              - key: ${key}\n"
        local l_string2="                operator: In\n"
        local l_string3="                values:\n"
        local l_string4="                - ${value}"
        sed -i "/matchExpressions:/a\\${l_string1}${l_string2}${l_string3}${l_string4}" \
            ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_RECOVERY_FILE}
    done
}

function template_restic_storage_handler {
    local restic_repository
    local nfs_server
    local nfs_path
    restic_repository="${RESTIC_REPOSITORY}"
    nfs_server="${NFS_SERVER}"
    nfs_path="${NFS_PATH}"


    case "${RESTIC_STORAGE}" in
    nfs)
        # TEMPLATE_BACKUP_FILE handler
        local vol_string1="          - name: restic\n"
        local vol_string2="            nfs:\n"
        local vol_string3="              server: ${nfs_server}\n"
        local vol_string4="              path: ${nfs_path}\n"
        local vol_string5="              readOnly: false"
        local volm_string1="            - name: restic\n"
        local volm_string2="              mountPath: ${restic_repository}"
        for file in ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_BACKUP_FILE}; do
            sed -i "/volumes:/a\\${vol_string1}${vol_string2}${vol_string3}${vol_string4}${vol_string5}" "${file}"
            sed -i "/volumeMounts:/a\\${volm_string1}${volm_string2}" "${file}"
        done

        # TEMPLATE_RECOVERY_FILE handler
        # TEMPLATE_RESTIC_INIT_FILE handler
        local vol_string1="      - name: restic\n"
        local vol_string2="        nfs:\n"
        local vol_string3="          server: ${nfs_server}\n"
        local vol_string4="          path: ${nfs_path}\n"
        local vol_string5="          readOnly: false"
        local volm_string1="        - name: restic\n"
        local volm_string2="          mountPath: ${restic_repository}"
        for file in ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}/${TEMPLATE_RECOVERY_FILE} \
                    ${TEMPLATE_DST_DIR}/${TEMPLATE_RESTIC_INIT_FILE}; do
            sed -i "/volumes:/a\\${vol_string1}${vol_string2}${vol_string3}${vol_string4}${vol_string5}" "${file}"
            sed -i "/volumeMounts:/a\\${volm_string1}${volm_string2}" "${file}"
        done
        ;;
    rbd)
        : ;;
    cephfs)
        : ;;
    *)
        echo "Not support restic storage ${RESTIC_STORAGE}, exit..."
        echo $EXIT_FAILURE
    esac
}

function template_restic_init_handler {
    local restic_init_config
    local restic_init_secret

    restic_init_config="backup-script-restic-config"
    restic_init_secret="backup-script-restic-secret"

    sed -i "s%#RESTIC_REPOSITORY#%${RESTIC_REPOSITORY}%"        ${TEMPLATE_DST_DIR}/${TEMPLATE_RESTIC_INIT_FILE}
    sed -i "s%#RESTIC_PASSWORD#%${RESTIC_PASSWORD}%g"           ${TEMPLATE_DST_DIR}/${TEMPLATE_RESTIC_INIT_FILE}
    sed -i "s%#RESTIC_BACKUP_IMAGE#%${RESTIC_BACKUP_IMAGE}%g"   ${TEMPLATE_DST_DIR}/${TEMPLATE_RESTIC_INIT_FILE}
    sed -i "s%#RESTIC_INIT_CONFIG#%${restic_init_config}%g"     ${TEMPLATE_DST_DIR}/${TEMPLATE_RESTIC_INIT_FILE}
    sed -i "s%#RESTIC_INIT_SECRET#%${restic_init_secret}%g"     ${TEMPLATE_DST_DIR}/${TEMPLATE_RESTIC_INIT_FILE}
}


# 三: 脚本主体，函数执行 ==============================================================#
function main {

    check_global_variable
    printf "\n"
    printf "CLUSTER_NAME:               %s\n" "${CLUSTER_NAME}"
    printf "RESTIC_PASSWORD:            %s\n" "${RESTIC_PASSWORD}"
    printf "RESTIC_STORAGE:             %s\n" "${RESTIC_STORAGE}"
    printf "RESTIC_REPOSITORY:          %s\n" "${RESTIC_REPOSITORY}"
    printf "\n"

    mapfile BACKUP_TARGET_LIST < <(ls ${K8S_PV_BACKUP_CONFIG_PATH} | grep -v global)
    # 如果没有提供 backup target，则退出脚本
    if [[ "${#BACKUP_TARGET_LIST[*]}" -eq 0 ]]; then
        echo "No backup target, exit..."
        exit ${EXIT_FAILURE}; fi


    # 循环处理每一个备份对象
    for file in ${BACKUP_TARGET_LIST[@]}; do
        check_backup_target_variable "${file}"
        check_restic_storage_variable "${file}"

        printf "BACKUP_TARGET_NAME:         %s\n" "${BACKUP_TARGET_NAME}"
        printf "BACKUP_TARGET_NAMESPACE:    %s\n" "${BACKUP_TARGET_NAMESPACE}"
        # 获取备份对象的类型
        #   1. 已知 BACKUP_TARGET_NAME 变量
        #   2. 已知 BACKUP_TARGET_NAMESPACE 变量 (此变量可选)
        #   3. 获取 BACKUP_TARGET_TYPE 变量
        get_backup_target_type ${BACKUP_TARGET_NAME} ${BACKUP_TARGET_NAMESPACE}
        # 如果没有获取到备份对象资源类型，即变量 BACKUP_TARGET_TYPE 为空，则退出脚本
        if [[ -z ${BACKUP_TARGET_TYPE} ]]; then
            echo "Cannot get the k8s resource type of [${BACKUP_TARGET_NAME}]"
            exit $EXIT_FAILURE; fi
        printf "BACKUP_TARGET_TYPE:         %s\n" "${BACKUP_TARGET_TYPE}"
        printf "RESTIC_SNAPSHOT_COUNT:      %s\n" "${RESTIC_SNAPSHOT_COUNT}"
        printf "RESTIC_BACKUP_SCHEDULE:     %s\n" "${RESTIC_BACKUP_SCHEDULE}"
        printf "NFS_SERVER:                 %s\n" "${NFS_SERVER}"
        printf "NFS_PATH:                   %s\n" "${NFS_PATH}"

        # 获取备份对象的 pvc list 和 label list
        #   1. 设置 BACKUP_TARGET_PVC_LIST 变量
        #   2. 设置 BACKUP_TARGET_LABEL_LIST 变量
        get_backup_target_pvc_and_labels \
            ${BACKUP_TARGET_NAME} ${BACKUP_TARGET_TYPE} ${BACKUP_TARGET_NAMESPACE}
        if [[ ${#BACKUP_TARGET_PVC_LIST[@]} -eq 0 ]]; then
            echo "Cannot get the ${BACKUP_TARGET_NAME} pvc"
            exit $EXIT_FAILURE; fi
        if [[ ${#BACKUP_TARGET_LABEL_LIST[@]} -eq 0 ]]; then
            echo "Cannot get the ${BACKUP_TARGET_NAME} labels"
            exit $EXIT_FAILURE; fi
        printf "BACKUP_TARGET_PVC_LIST:     %s"
        for pvc in "${BACKUP_TARGET_PVC_LIST[@]}"; do
            printf "%s " ${pvc}; done
        printf "\n"
        printf "BACKUP_TARGET_LABEL_LIST:   %s"
        for key in "${!BACKUP_TARGET_LABEL_LIST[@]}"; do
            value=${BACKUP_TARGET_LABEL_LIST[$key]}
            printf "%s: %s  " $key $value; done
        printf "\n\n"

        mkdir -p ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}
        yes | cp -rf ${TEMPLATE_SRC_DIR}/${TEMPLATE_RESTIC_INIT_FILE}   ${TEMPLATE_DST_DIR}/${TEMPLATE_RESTIC_INIT_FILE}
        yes | cp -rf ${TEMPLATE_SRC_DIR}/${TEMPLATE_BACKUP_FILE}        ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}
        yes | cp -rf ${TEMPLATE_SRC_DIR}/${TEMPLATE_RECOVERY_FILE}      ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}
        yes | cp -rf ${TEMPLATE_SRC_DIR}/${TEMPLATE_CONFIGMAP_FILE}     ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}
        yes | cp -rf ${TEMPLATE_SRC_DIR}/${TEMPLATE_SECRET_FILE}        ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}
        template_common_handler
        template_pvc_handler
        template_label_handler
        template_restic_storage_handler
        template_restic_init_handler

        # restic init
        kubectl -n ${K8S_PV_BACKUP_NAMESPACE} delete configmap backup-script-restic clean-script-restic &> /dev/null
        kubectl -n ${K8S_PV_BACKUP_NAMESPACE} create configmap backup-script-restic --from-file ${K8S_PV_BACKUP_PATH}/restic/backup-script-restic.sh
        kubectl -n ${K8S_PV_BACKUP_NAMESPACE} create configmap clean-script-restic --from-file ${K8S_PV_BACKUP_PATH}/restic/clean-script-restic.sh
        kubectl -n ${K8S_PV_BACKUP_NAMESPACE} apply -f ${TEMPLATE_DST_DIR}/${TEMPLATE_RESTIC_INIT_FILE}

        # backup target
        kubectl -n ${BACKUP_TARGET_NAMESPACE} delete configmap backup-script-restic clean-script-restic &> /dev/null
        kubectl -n ${BACKUP_TARGET_NAMESPACE} create configmap backup-script-restic --from-file ${K8S_PV_BACKUP_PATH}/restic/backup-script-restic.sh
        kubectl -n ${BACKUP_TARGET_NAMESPACE} create configmap clean-script-restic --from-file ${K8S_PV_BACKUP_PATH}/restic/clean-script-restic.sh
        kubectl apply -f ${TEMPLATE_DST_DIR}/${BACKUP_TARGET_NAME}
        printf "\n"
    done
}
main
