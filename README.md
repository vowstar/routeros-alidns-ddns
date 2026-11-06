# routeros-alidns-ddns

RouterOS-native dynamic DNS updater for Alibaba Cloud DNS (AliDNS), in one
~11 KB `.rsc` file. No container, no external host, no MikroTik cloud DDNS.

## What it does

The script runs entirely on the router. On every run it:

1. Reads the IPv6 GUA (global unicast, `2xxx::/3`) assigned to a chosen
   interface, plus the public IPv4 reported by `/ip cloud`.
2. `DescribeDomainRecords` for each configured record to compare the current
   value against the local address.
3. Calls `UpdateDomainRecord` only when the value actually differs, then logs
   the outcome.

Up to four records are maintained: the plain name (A and AAAA), plus `.v4` and
`.v6` variants that pin a single address family.

## Why

The AliDNS RPC API requires every request to be signed with HMAC-SHA1 over an
RFC 3986 percent-encoded canonical query string. RouterOS scripting has no
hash or HMAC primitive at all, and the API rejects unsigned requests. This
project therefore ships a pure-RouterOS implementation of:

- SHA-1 (verified against the RFC 3174 test vectors),
- HMAC-SHA1 (verified against the RFC 2202 test vectors),
- RFC 3986 percent-encoding,
- ISO 8601 UTC timestamps computed from `/system clock`,
- the AliDNS `SignatureVersion=1.0` canonical request and signature.

Cost on an RB5009: roughly 100 ms per signed request. Script size is about
11 KB.

## Requirements

- RouterOS **7.16 or newer** (needs `:convert to=byte-array` and
  `:convert from=byte-array to=base64`).
- An Alibaba Cloud **RAM user** whose policy is limited to
  `AddDomainRecord`, `DescribeDomainRecords` and `UpdateDomainRecord` on a
  single domain.
- The records **created beforehand** in the Alibaba Cloud console, with their
  **RecordIds** copied out. The script updates records; it does not create
  them in normal operation.
- Record TTL **600 s** (the AliDNS minimum on typical accounts). A 5-minute
  scheduler interval matches this floor.

## Setup

### 1. Create the RAM policy

Create a RAM user (programmatic access only), then attach a custom policy.
Replace `example.com` with your domain:

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "alidns:AddDomainRecord",
        "alidns:DescribeDomainRecords",
        "alidns:UpdateDomainRecord"
      ],
      "Resource": "acs:alidns:*:*:domain/example.com"
    }
  ]
}
```

Save the AccessKeyId and AccessKeySecret for the next step.

### 2. Create the records and copy their RecordIds

In the Alibaba Cloud DNS console, create the records you need, for example:

| RR        | Type | Value                     |
|-----------|------|---------------------------|
| `home`    | A    | (any placeholder address) |
| `home`    | AAAA | (any placeholder address) |
| `home.v4` | A    | (any placeholder address) |
| `home.v6` | AAAA | (any placeholder address) |

Open each record and copy its **RecordId**. You need one RecordId per record.

### 3. Fill the configuration globals

Edit the block at the top of `alidns-ddns.rsc`:

| Global          | Meaning                                                        |
|-----------------|----------------------------------------------------------------|
| `alidnsAKID`    | RAM AccessKeyId.                                               |
| `alidnsAKSEC`   | RAM AccessKeySecret.                                           |
| `alidnsRR`      | Base record name, e.g. `home` (the `.v4`/`.v6` suffixes are added by the script). |
| `alidnsRID6`    | RecordId of the AAAA record on the plain name `home`.          |
| `alidnsRID6V`   | RecordId of the AAAA record on `home.v6`.                      |
| `alidnsRID4`    | RecordId of the A record on the plain name `home`.             |
| `alidnsRID4V`   | RecordId of the A record on `home.v4`.                         |
| `alidnsIFC`     | Interface whose IPv6 GUA is published, e.g. `bridge1`.         |
| `alidnsDomain`  | Zone name, e.g. `example.com`. Used by Describe.               |

**CGNAT sites:** leave `alidnsRID4` and `alidnsRID4V` **empty** (`""`). The
router's `/ip cloud` address is then a carrier address and must not be
published; the script skips the A records and maintains only AAAA.

### 4. Upload the script

```sh
scp -O alidns-ddns.rsc admin@192.0.2.1:
```

`-O` forces the legacy SCP protocol, which older RouterOS builds and some
OpenSSH versions require. SFTP also works:
`sftp admin@192.0.2.1` then `put alidns-ddns.rsc`.

### 5. Import once

```
/import file=alidns-ddns.rsc
```

The file declares the globals, then calls `$alidnsRun` at the end, so a single
import performs one update pass.

### 6. Schedule it

```
/system scheduler add name=alidns-ddns start-time=startup interval=5m on-event="/import file=alidns-ddns.rsc"
```

Every run re-imports the file: configuration is re-declared and one pass is
executed. This keeps the configuration in one place instead of duplicating it
in the scheduler. Note that globals only live for the current session unless
re-imported this way, which is exactly why the scheduler imports the file
rather than calling `$alidnsRun` directly.

## Records layout advice

- **Plain name** (`home`): point it at every address family that is really
  reachable from the Internet. A dual-stack site gets A + AAAA; a CGNAT site
  gets AAAA only.
- **`.v4` / `.v6` names**: use these when a consumer must force one family.
  WireGuard endpoint selection from a dual-stack hostname is not
  deterministic across implementations and platforms, so configure the peer
  with `home.v4` or `home.v6` explicitly rather than relying on a preference
  order.
- Publishing an address that is not actually reachable (CGNAT IPv4, or a
  firewall that blocks the port) only creates confusing failure modes.

## Verification

```
/log print where message~"alidns"
```

Each record logs one of:

- `alidns: home AAAA unchanged 2001:db8::1` — nothing to do.
- `alidns: home AAAA -> 2001:db8::2` — the record was updated.

Confirm from an external host:

```sh
dig +short AAAA home.example.com
dig +short A home.example.com
```

## Troubleshooting

**HTTP 400 `DomainRecordDuplicate`.** AliDNS returns this when the requested
value already exists on the record. RouterOS `/tool fetch` raises an error on
any 4xx response and does not expose the response body, so the error cannot be
inspected on the device. That is why the script calls Describe first and only
updates when the value differs; on a converged record you should see
`unchanged`, never a duplicate error.

**`SignatureNonceUsed`.** Every request needs a unique `SignatureNonce`. The
script composes it from the current epoch seconds plus a persistent counter.
This error means two runs collided within the same second (for example two
manual imports at once) or the system clock jumped backwards.

**Signature errors after a reboot / clock skew.** The `Timestamp` parameter is
taken from `/system clock` and must be within roughly 15 minutes of UTC.
Enable NTP (`/system ntp client set enabled=yes`) and verify
`/system clock print` shows the correct time and `gmt-offset`.

**AAAA lookups fail although the record is correct.** If the router's own
resolver is a proxy or a container DNS that drops AAAA queries, clients behind
it cannot see the AAAA record. As a workaround, forward your own zone to an
existing DoH forwarder:

```
/ip dns static add name=example.com type=FWD forward-to=<doh-forwarder> match-subdomain=yes
```

This is troubleshooting, not a required setup step.

## Security

- The AccessKey pair is stored in the router configuration and is readable by
  anyone with administrative access to the device. Treat router admin access
  as equivalent to Alibaba Cloud DNS write access to that zone.
- Scope the RAM user to the single domain and to the three actions listed
  above. Do not reuse an account-level key.
- Enable Alibaba Cloud ActionTrail (audit) for the account so API calls by the
  key are recorded.
- If the device is compromised, lost or sold, disable/rotate the AccessKey
  immediately and re-import the script with the new values.
- Do not commit a filled-in copy of the script to a public repository; keep
  `.secret` files ignored (see `.gitignore`).

## Limitations

- Script size and CPU cost are negligible on modern hardware (~11 KB,
  ~100 ms per signed request on an RB5009), but on very old or heavily loaded
  devices a 5-minute interval is still the practical floor.
- AliDNS enforces a TTL floor of 600 s on typical accounts; shorter values are
  rejected or silently raised.
- Wildcard records (`*`) are not supported by this script.
- Only A and AAAA records are managed. There is no CNAME/TXT support and no
  automatic record creation beyond what `AddDomainRecord` would allow (the
  normal path assumes the records already exist).
- The IPv6 selection takes the first GUA on the interface; multiple GUAs or
  privacy/temporary addresses are not distinguished.

---

# routeros-alidns-ddns（中文）

RouterOS 原生的阿里云 DNS（AliDNS）动态域名更新脚本，单个约 11 KB 的
`.rsc` 文件。不需要容器、不需要外部主机、不使用 MikroTik 云 DDNS。

## 功能

脚本完全在路由器上运行。每次执行时：

1. 读取指定接口上的 IPv6 GUA（全球单播，`2xxx::/3`）以及 `/ip cloud`
   报告的公网 IPv4 地址。
2. 对每条配置的记录调用 `DescribeDomainRecords`，把当前值和本地地址比较。
3. 只有值确实不同时才调用 `UpdateDomainRecord`，然后记录日志。

最多维护四条记录：主域名（A 与 AAAA），以及固定单一地址族的 `.v4` 与
`.v6` 变体。

## 为什么需要它

阿里云 DNS 的 RPC API 要求对 RFC 3986 百分号编码后的规范查询串做
HMAC-SHA1 签名，而 RouterOS 脚本没有任何哈希/HMAC 原语，未签名的请求会
被直接拒绝。因此本项目用纯 RouterOS 脚本实现了：

- SHA-1（已用 RFC 3174 测试向量验证），
- HMAC-SHA1（已用 RFC 2202 测试向量验证），
- RFC 3986 百分号编码，
- 基于 `/system clock` 计算的 ISO 8601 UTC 时间戳，
- AliDNS `SignatureVersion=1.0` 的规范请求与签名。

在 RB5009 上每个签名请求约 100 ms，脚本约 11 KB。

## 环境要求

- RouterOS **7.16 或更新版本**（需要 `:convert to=byte-array` 与
  `:convert from=byte-array to=base64`）。
- 一个阿里云 **RAM 用户**，权限仅限单个域名的 `AddDomainRecord`、
  `DescribeDomainRecords`、`UpdateDomainRecord`。
- 记录需**事先在控制台创建**，并抄下各自的 **RecordId**。脚本负责更新，
  常规流程中不负责创建。
- 记录 TTL 设为 **600 秒**（典型账号下 AliDNS 的最小值）。调度器 5 分钟
  的间隔正好对应这个下限。

## 配置步骤

### 1. 创建 RAM 策略

创建仅用于编程访问的 RAM 用户，并附加自定义策略（把 `example.com`
换成本人的域名）：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "alidns:AddDomainRecord",
        "alidns:DescribeDomainRecords",
        "alidns:UpdateDomainRecord"
      ],
      "Resource": "acs:alidns:*:*:domain/example.com"
    }
  ]
}
```

记下 AccessKeyId 与 AccessKeySecret。

### 2. 创建记录并抄下 RecordId

在阿里云 DNS 控制台创建所需记录，例如：

| RR        | 类型 | 值               |
|-----------|------|------------------|
| `home`    | A    | 任意占位地址     |
| `home`    | AAAA | 任意占位地址     |
| `home.v4` | A    | 任意占位地址     |
| `home.v6` | AAAA | 任意占位地址     |

打开每条记录，复制其 **RecordId**。每条记录对应一个 RecordId。

### 3. 填写配置全局变量

编辑 `alidns-ddns.rsc` 顶部的配置块：

| 全局变量       | 含义                                                            |
|----------------|-----------------------------------------------------------------|
| `alidnsAKID`   | RAM 的 AccessKeyId。                                            |
| `alidnsAKSEC`  | RAM 的 AccessKeySecret。                                        |
| `alidnsRR`     | 基础记录名，例如 `home`（`.v4`/`.v6` 后缀由脚本追加）。         |
| `alidnsRID6`   | 主名 `home` 上 AAAA 记录的 RecordId。                           |
| `alidnsRID6V`  | `home.v6` 上 AAAA 记录的 RecordId。                             |
| `alidnsRID4`   | 主名 `home` 上 A 记录的 RecordId。                              |
| `alidnsRID4V`  | `home.v4` 上 A 记录的 RecordId。                                |
| `alidnsIFC`    | 发布其 IPv6 GUA 的接口，例如 `bridge1`。                        |
| `alidnsDomain` | 区域名，例如 `example.com`，供 Describe 使用。                  |

**CGNAT 站点**：把 `alidnsRID4` 与 `alidnsRID4V` 留**空**（`""`）。此时
`/ip cloud` 得到的是运营商地址，绝不能发布；脚本会跳过 A 记录，只维护
AAAA。

### 4. 上传脚本

```sh
scp -O alidns-ddns.rsc admin@192.0.2.1:
```

`-O` 强制使用旧版 SCP 协议，较老的 RouterOS 构建和部分 OpenSSH 版本需要
它。也可以用 SFTP：`sftp admin@192.0.2.1`，再 `put alidns-ddns.rsc`。

### 5. 手动导入一次

```
/import file=alidns-ddns.rsc
```

文件先声明全局变量，末尾调用 `$alidnsRun`，因此一次导入即完成一轮更新。

### 6. 加入调度器

```
/system scheduler add name=alidns-ddns start-time=startup interval=5m on-event="/import file=alidns-ddns.rsc"
```

每次执行都重新导入文件：重新声明配置并跑一轮。这样配置只保留在一处，
不必在调度器里重复。注意全局变量只在当前会话有效，必须靠每次导入来重建，
这也正是调度器导入整个文件而不是直接调用 `$alidnsRun` 的原因。

## 记录布局建议

- **主域名**（`home`）：指向所有真正可达的地址族。双栈站点配置 A + AAAA；
  CGNAT 站点只配置 AAAA。
- **`.v4` / `.v6` 名称**：当对端必须强制某一地址族时使用。从双栈域名做
  WireGuard 端点选择在不同实现/平台上并不确定，因此对端应显式配置
  `home.v4` 或 `home.v6`，不要依赖优先级顺序。
- 发布实际不可达的地址（CGNAT 的 IPv4，或被防火墙挡住端口的地址）只会
  制造难以排查的故障。

## 验证

```
/log print where message~"alidns"
```

每条记录会输出以下之一：

- `alidns: home AAAA unchanged 2001:db8::1` —— 无需改动。
- `alidns: home AAAA -> 2001:db8::2` —— 记录已更新。

再从外部主机确认：

```sh
dig +short AAAA home.example.com
dig +short A home.example.com
```

## 故障排查

**HTTP 400 `DomainRecordDuplicate`。** 当请求的值已经存在于该记录时，
AliDNS 会返回此错误。RouterOS 的 `/tool fetch` 对任何 4xx 都直接抛错且不
暴露响应体，设备上无法查看错误内容。因此脚本先 Describe，只有值不同才
更新；记录已收敛时应看到 `unchanged`，而不是重复记录错误。

**`SignatureNonceUsed`。** 每个请求的 `SignatureNonce` 必须唯一。脚本用
当前纪元秒加一个持久计数器拼接而成。出现该错误意味着同一秒内两次运行
撞车（例如同时手动导入两次），或系统时钟回退。

**重启后签名错误 / 时钟偏移。** `Timestamp` 取自 `/system clock`，必须与
UTC 相差约 15 分钟以内。请启用 NTP（`/system ntp client set enabled=yes`），
并用 `/system clock print` 确认时间和 `gmt-offset` 正确。

**记录正确但 AAAA 解析失败。** 如果路由器自身的解析器是代理或容器 DNS 并
丢弃 AAAA 查询，其后的客户端就看不到 AAAA 记录。可以把自有区域转发到一个
现成的 DoH 转发器作为变通：

```
/ip dns static add name=example.com type=FWD forward-to=<doh-forwarder> match-subdomain=yes
```

这是排查手段，不是必需步骤。

## 安全

- AccessKey 保存在路由器配置中，任何拥有设备管理权限的人都能读取。请把
  路由器的管理权限等同于对该域名在阿里云 DNS 上的写权限。
- RAM 用户只授权单个域名和上面列出的三个动作，不要复用账号级密钥。
- 为账号启用阿里云 ActionTrail（审计），以便记录该密钥的 API 调用。
- 若设备被入侵、丢失或转手，立即禁用/轮换 AccessKey，并用新值重新导入
  脚本。
- 不要把填好密钥的脚本提交到公开仓库；`.secret` 类文件已被 `.gitignore`
  忽略。

## 限制

- 脚本体积与 CPU 开销在现代硬件上可以忽略（约 11 KB，在 RB5009 上每个
  签名请求约 100 ms），但在非常老或负载很高的设备上，5 分钟仍是实际可用的
  最小间隔。
- 典型账号下 AliDNS 的 TTL 下限为 600 秒，更小的值会被拒绝或静默提高。
- 本脚本不支持通配符记录（`*`）。
- 只管理 A 与 AAAA 记录，不支持 CNAME/TXT；正常流程假定记录已存在，不依赖
  自动创建。
- IPv6 选择取接口上的第一个 GUA，不区分多 GUA、隐私地址或临时地址。
