---
content_hash: sha256:c7d57feab66459682e415ce469709ac21e22c2223182379caec6fefde8058a84
crawled_at: '2026-05-28T18:54:24.649405+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_main_account_to_sub_account.html
tags:
- bitunix-api-future
- web-docs
title: transfer asset from main account to sub account | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_main_account_to_sub_account.html#VPContent)
Menu
Return to top
# transfer asset from main account to sub account [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_main_account_to_sub_account.html#transfer-asset-from-main-account-to-sub-account)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_main_account_to_sub_account.html#description)
Interface is used to transfer asset from main Account to subAccount.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_main_account_to_sub_account.html#http-request)
  * POST /api/v1/cp/asset/transfer-to-sub-account

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_main_account_to_sub_account.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| amount  | string  | true  | transfer amount  |
| assetType  | string  | true  | Assets are transferred from the futures account or spot account of the main account. eg: FUTURES/SPOT  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/cp/asset/transfer-to-sub-account' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"amount":"10","assetType":"SPOT"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/copyTrading/asset/transfer_asset_from_main_account_to_sub_account.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
Response Example
json
```
{"code":0,"msg":"result.success","data":"","success":true}
```