/* redactSecrets 的自检。跑法:`npm run check:telemetry`(Node 直接跑 .ts,零测试框架)。
   为什么值得留:这是**数据离开用户机器前的最后一道过滤**。本项目的 Emby 请求 URL 里
   就带着 api_key,而前端报错消息常年把整条 URL 带上 —— 正则写漏一个分支 = 把用户的
   服务器令牌批量寄给 Sentry。这种东西不能靠「看着对」。

   ★ 证明过会红:把 SECRET_QUERY 里的 "api_key" 删掉,第 1 条断言当场挂在
     `got: ...api_key=abc123...`。 */

import { redactSecrets } from "./telemetry.ts";
import assert from "node:assert/strict";

const cases: [string, string, string][] = [
  [
    "Emby 的 api_key 必须抹掉,Limit 这类无害参数必须留",
    "https://emby.example.com/Items?api_key=abc123&Limit=50",
    "https://emby.example.com/Items?api_key=<redacted>&Limit=50",
  ],
  [
    "首个参数(? 后)和后续参数(& 后)都要覆盖",
    "/Users?token=t1&SortBy=Name&access_token=t2",
    "/Users?token=<redacted>&SortBy=Name&access_token=<redacted>",
  ],
  ["大小写不敏感", "/x?API_KEY=zz", "/x?API_KEY=<redacted>"],
  ["不带 query 的普通文本原样不动", "failed to parse response", "failed to parse response"],
  ["无关的 key=value 不能被误伤", "/x?ParentId=17&Recursive=true", "/x?ParentId=17&Recursive=true"],
  ["网盘 Cookie 类的 sign 也要抹", "https://pan/api?sign=deadbeef&fid=9", "https://pan/api?sign=<redacted>&fid=9"],
];

for (const [name, input, want] of cases) {
  const got = redactSecrets(input);
  assert.equal(got, want, `${name}\n  got:  ${got}\n  want: ${want}`);
}

// 兜底:抹完之后原始密钥不能以任何形式残留。
const secret = "supersecrettoken";
assert.ok(!redactSecrets(`/Items?api_key=${secret}`).includes(secret), "密钥残留");

console.log(`OK  redactSecrets: ${cases.length + 1} 条断言全过`);
