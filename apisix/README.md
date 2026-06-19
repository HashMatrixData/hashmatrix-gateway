# apisix/ —— 网关声明式配置（config-as-code）

本目录是 APISIX 的全部配置，采用 **standalone / 声明式 YAML 模式**：配置事实源(SoT)就在 Git 里，**无 etcd**。

| 文件 | 作用 | 是否热加载 |
|--|--|--|
| `config.yaml` | 启动期静态配置：监听端口、`deployment.role=data_plane`、`config_provider=yaml`、启用的插件集 | 否（改后需重启容器） |
| `apisix.yaml` | 运行期声明式资源：routes / upstreams / 插件配置 | **是**（保存即热加载，约 1s） |

## 为什么是 standalone（而非 etcd 传统模式）

- **配置即代码**：`apisix.yaml` 本身就是唯一事实源，不存在「Git 文件 ↔ etcd」两份配置漂移的问题。
- **去状态耦合**：不把业务路由/插件配置塞进 etcd，少运维一套有状态组件，契合 K8s/GitOps（ConfigMap + Reloader / ArgoCD）。
- **热加载**：APISIX 周期性检测 `apisix.yaml` 的 mtime 并自动 reload，无需重启、无需 Admin API。

> ⚠️ 本地 macOS Docker Desktop 对「单文件 bind mount」会缓存 mtime，导致自动 reload 在本机不触发（内容可见但 mtime 冻结）——属环境限制。`scripts/hot-reload.sh` 会自动回退优雅重启；Linux/CI/生产(ConfigMap) 上走真正的自动热加载分支。详见 [`../scripts/README.md`](../scripts/README.md)。

> 生产部署：本目录的 `apisix.yaml` / `config.yaml` 经主仓 `deploy/charts/gateway` 渲染为 ConfigMap 注入 APISIX（见该子 chart）。

## 关键约定

- `apisix.yaml` **必须以 `#END` 结尾**（standalone 模式的结束标记）。
- 启用自定义插件：在 `config.yaml` 的 `plugins:` 列表登记插件名（如 `tenant-context`），并把 `plugins/*.lua` 挂载到容器的 `apisix/plugins/` 路径（见 `docker-compose.local.yml`）。`plugins:` 显式声明会**覆盖**默认插件集，故需列全用到的插件。

## 本地 compose vs 集群（部署级注入点）

本目录的 `apisix.yaml` 是**本地 compose 自洽**的事实源（mock 上游、同名 Keycloak Service，一 clone 即跑）。**集群**部署不直接 copy 本文件——主仓 `deploy/charts/gateway` 渲染一份**集群版** `apisix.yaml`（`templates/configmap.yaml`），把 env-specific 字段经 **values → ConfigMap** 注入。两处职责切分如下（标 🌱 的两点即 `apisix.yaml` 内注释的注入点）：

| 注入点 | 本地 compose 值 | 集群来源（唯一事实源） | 集群默认 |
|--|--|--|--|
| 🌱① 上游目标 | `mock-upstream:8080`（go-httpbin 回显头） | chart `values.upstreams.governance.{host,port}` | `governance:8082`（跨 ns 用 FQDN `governance.<ns>.svc:8082`） |
| 🌱② OIDC discovery | `http://keycloak:8080/realms/hashmatrix/...` | chart `values.oidc.discovery` | in-cluster Keycloak（同名 `keycloak:8080`；跨 ns 用 FQDN `keycloak.<ns>.svc:8080`） |

> 🔒 **集群侧端口对齐基线**：governance 应用容器端口 **8082**（`8084` 是 data-foundation，勿混）；Keycloak 集群内 Service→Pod 用 **8080**（基线 `8180` 仅宿主/dev 暴露，勿写进集群 discovery）。

**无双源/漂移**：集群值的**唯一事实源是 chart values**，本文件**不复制**集群值——只在两个注入点用注释标明「此处本地值、集群由 chart 注入」。其余配置/插件按下表流转：

| 来源（本目录 / `../plugins`） | 集群处理 | 同步方式 |
|--|--|--|
| `config.yaml`（静态，env-agnostic） | vendored 副本 → ConfigMap | `bash deploy/scripts/sync-gateway-config.sh`（`--check` 即漂移门） |
| `../plugins/*.lua` | vendored 副本 → ConfigMap（subPath 挂载） | 同上 |
| `apisix.yaml`（声明式） | **不 copy**：chart 渲染集群版（结构镜像本文件，注入点按 values） | 不同步（走模板） |

> ⚠️ **集群版只落贯通必需路由**（M1 I2：`protected-api` + 可达性探活 `public-open`）；本地演示/限流路由（如 `ratelimit-demo`）与 mock 上游**仅本地自洽**、不入集群。`admin-api`（superadmin 管理平面，见本目录「admin 平面」节）M1 **集群暂不落地**——待 control-plane 管理面接通后，再按本规则同步进 chart。集群路由的权威清单以 chart `templates/configmap.yaml` 为准——**本目录新增受保护路由时，需在 chart 侧手工同步扩展**（见主仓 [`deploy/charts/gateway/README.md`](https://github.com/HashMatrixData/hashmatrix/tree/main/deploy/charts/gateway)）。

## 路由与插件链

受保护路由共享 `plugin_config: auth-tenant`（`openid-connect` + `tenant-context` + `audit-log`，DRY），再各自叠加 `proxy-rewrite` 与 `limit-count`：

```
请求 → proxy-rewrite → openid-connect(验签, 无/坏 token→401, 注入 X-Userinfo)
     → tenant-context(读 X-Userinfo → 注入 X-Tenant-* + 暴露 $tenant_id; 无 X-Userinfo→fail-closed)
     → limit-count(key=$tenant_id, 按租户配额) → audit-log → 上游
```

| 路由 | 鉴权 | 说明 |
|--|--|--|
| `/api/*` | ✅ auth-tenant | 受保护 API，按租户 100/min |
| `/ratelimit/*` | ✅ auth-tenant | 限流样例，按租户 2/60s（便于冒烟验证每租户独立配额） |
| `/admin/*` | ✅ auth-tenant（`require_tenant=false`） | admin/superadmin 平面：OIDC 校验通过即放行，**不要求租户上下文** |
| `/public/*` | ❌ | 公共开放端点；含 `response-rewrite`，用于热加载演示 |

> 🔒 `openid-connect` 与 `tenant-context` 通过共享 `plugin_config` 绑定为一对——漏配前者时后者 fail-closed，杜绝静默注入伪造租户。详见 [`../plugins/README.md`](../plugins/README.md)。

### admin 平面：复用 `auth-tenant` + 路由级覆盖（不另建 plugin_config）

`/admin/*` 服务**不绑 org 的 superadmin**（管理平面无租户上下文）。它**复用**同一 `auth-tenant`（`openid-connect` 仍验签、`audit-log` 仍审计），仅在路由级把 `tenant-context` 覆盖为 `require_tenant: false`：

```yaml
  - id: admin-api
    uri: /admin/*
    plugin_config_id: auth-tenant
    plugins:
      tenant-context:
        require_tenant: false   # 路由级同名插件优先于 plugin_config，整块替换；其余字段沿用插件默认
```

- **为什么不另建 `auth-admin`**：`openid-connect` 的 `discovery`/`client_id` 是易漂移的关键配置，单一事实源更稳；路由级覆盖只动 `tenant-context` 一项，OIDC 与审计零重复。
- **语义**：路由级同名插件**整块替换** `plugin_config` 中的同名插件（非深合并），故覆盖块只需写差异项 `require_tenant: false`，其余字段由插件 schema 默认补齐（与 `auth-tenant` 一致）。
- **安全不降级**：`require_tenant=false` 仅放宽「无租户即放行」；进入仍**剥离**客户端伪造的 `X-Tenant-*`，superadmin 无 org 声明 → **不注入**任何租户头（不会被错注租户）。同一 superadmin 打 `/api/*` 仍 `require_tenant=true` → fail-closed `403`。
