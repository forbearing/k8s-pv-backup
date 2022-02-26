

## k8s-pv-backup 功能

- 支持将 pv/pvc 中的数据备份到 nfs 存储
- 支持将 pv/pvc 中的数据备份到 minio 存储
- 支持将 pv/pvc 中的数据备份到 cephfs 存储
- 支持将 pv/pvc 中的数据备份到 S3 存储
- 支持将数据从 nfs/minio/cephfs/S3 存储中的备份数据恢复到 pv/pvc
- 支持备份 Pod/Deployment/StatefulSet/DaemonSet（根据配置文件 ConfigMap 来指定需要备份的微服务列表）
- pv/pvc 克隆：pvc-A --> pvc-A-clone
- pv/pvc 迁移：从一个 StorageClass 迁移到另外的一个 StorageClass 中
- 备份工具用的是 [restic](https://github.com/restic/restic), restic 支持 snapshot，所以 k8s-pv-backup 也支持 snapshot

## 原理

- k8s-pv-backup 根据配置文件(ConfigMap) 来为指定的的微服务(Pod/Deployment/StatefulSet/DaemonSet) 创建 CronJob，CronJob 指定备份周期，比如每天备份一次，每天的凌晨1点开始备份等。
- CronJob 生成的 Pod 将 pv/pvc 中的数据备份到 nfs/minio/cephfs/S3 等存储中。
- 在配置文件(ConfigMap) 中增删改需要备份的微服务，k8s-pv-backup 会监控配置文件变化，会自动增删改备份对象的 CronJob。

- 备份工具用的是 [restic](https://github.com/restic/restic)。

## 什么时候传上来

我自己先踩坑，差不多够稳定了再发出来。





## 介绍

### 备份类型支持

- 全量备份 full backup
- 累计增量备份 cumulative incremental backup
- 差异增量备份 differential incremental backup

### [Cumulative Incremential Backup] vs [Differential Incremental Backup]

```
Cumulative Incremental:   This will backup all changes this the last Full backup.
Differential Incremental: This will backup all changes since last backup - Full or Incremental.

总结来说就是：
  - Cumulative Incremental:  更占存储空间，但恢复备份的速度更快
  - Differential Incremental: 占用存储空间相对少，当然恢复备份的速度想对更慢
```

### 具体如何恢复，稍等下再写

### Jenkins 备份和恢复测试没问题

### 后续还会增加更多的备份对象、优化通用备份脚本、给通用备份脚本添新功能

- gitlab、jenkins
- postgresql、gitlab
- cassandra、redis
- 等等

### 以后直接做成 helm 包

### 截图

![jenkins_backup_kubectl](docs/pics/jenkins_backup_kubectl_get.png)

<img src="docs/pics/jenkins_backup_kubectl_logs1.png" alt="jenkins_backup_kubectl_logs" style="zoom:80%;" />

<img src="docs/pics/jenkins_backup_kubectl_logs2.png" alt="jenkins_backup_kubectl_logs2" style="zoom:80%;" />



![jenkins_backup_tree](docs/pics/jenkins_backup_tree.png)

