# 第三方 IP 与许可说明

## Cortex-M0 DesignStart

本工程的 CPU 封装依赖 ARM Cortex-M0 DesignStart RTL：

```text
CORTEXM0INTEGRATION.v
cortexm0ds_logic.v
```

原文件的版权头将其标记为 ARM 的 confidential/proprietary information，并要求只能由具有有效许可的人员按许可范围使用和复制。因此本 GitHub 资料包不包含这两个实现文件。

授权用户可以通过以下任一方式在本地使用：

1. 将两文件复制到 `rtl/cortex_m0/vendor/`；
2. 设置环境变量 `ARM_CORTEX_M0_RTL_DIR` 指向包含这两文件的目录。

在公开仓库、比赛附件或网盘中重新分发前，应由团队自行核对所持 DesignStart 许可。此说明不是法律意见。

## Xilinx / AMD 工具产物

仓库不提交 Vivado 安装文件、器件数据库、仿真器二进制和自动生成缓存。使用者需要自行安装有权使用的 Vivado 2019.2。

## 本项目许可证

本包没有擅自给团队的自研 RTL 和软件添加开源许可证。公开发布前应确认共同作者归属，并由团队选择 LICENSE；没有 LICENSE 的公开仓库默认仍受版权保护。

