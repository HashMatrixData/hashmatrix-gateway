# hashmatrix-gateway

> hashmatrix 数据中台子模块 · 所属：网关层
>
> 主仓：[HashMatrixData/hashmatrix](https://github.com/HashMatrixData/hashmatrix)

## 产品形态与多租户（北极星）

**双模交付**：公网 SaaS（我们运营 · 统一**我们品牌** · 租户=企业）／私有化部署（客户环境 · **客户品牌**部署级 · 租户=客户部门）。品牌**部署级**、不按租户运行期换肤。多租户走 **C 分层桥接**：控制平面共享 + 数据平面按租户隔离（Keycloak Organizations 单 realm · schema/db-per-tenant · namespace-per-tenant），由 `control-plane` 编排开通。

**本仓视角**：校验 Keycloak OIDC，从 JWT org 声明**注入 `X-Tenant-*` 头**——租户上下文入口。

> 详见主仓 `docs/00-主仓初始化-spec.md`、`docs/architecture/05-多租户与控制平面.md`。

## 职责

南北向网关配置与插件：路由/限流/鉴权(OIDC)/审计。APISIX 或 Spring Cloud Gateway 待定。

## 技术栈

网关配置（**具体技术选型待独立讨论，逐步丰富**）

## 说明

本仓库作为 `hashmatrix` 主仓的 git submodule，挂载于 `services/gateway`。架构背景见主仓 `docs/architecture/`。

## License

Apache-2.0
