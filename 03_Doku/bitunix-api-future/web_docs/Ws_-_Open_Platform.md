---
content_hash: sha256:506ecabd4c5953656895b26ea207c41e0efd8c47a41dc9c9512397d9d838af9a
crawled_at: '2026-05-28T18:54:25.019317+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/spots/en_us/ws/
tags:
- bitunix-api-future
- web-docs
title: Ws - Open Platform
tool_used: crawl4ai
---

# Ws
##  [Quick Start](https://www.bitunix.com/api-docs/spots/en_us/)[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#quick-start "Permanent link")
## Restful API[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#restful-api "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public/)[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#public-interface "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user/)[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#user-interface "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order/)[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#order-interface "Permanent link")
## WebSocket API[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#websocket-api "Permanent link")
### WebSocket Introduction[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#websocket-introduction "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#public-interface_1 "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#user-interface_1 "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#order-interface_1 "Permanent link")
#### WebSocket API Introduction[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#websocket-api-introduction "Permanent link")
  * Base URL for the wss interfaces listed here: wss://openapi.bitunix.com:443/ws-api/v1
  * Timestamps are millisecond timestamps unless otherwise noted
  * All field names and values are case sensitive.
  * websocket connections are valid for 24 hours, please be careful to handle reconnections in case of disconnection.

#### Request Format[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#request-format "Permanent link")
WebSocket API requests must be transmitted in Json format in text frames, where a text frame message represents one request, example:

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "market.last_price",
  "params": {
    "symbol": "BTC",
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "477eda21f570dd4e2f7392b729254d12bc2d403d1150d0b6cfdb52191267550c"
  }
}

```

**String Explaination**
| Name  | Type  | Mandatory  | Description  |
| --- | --- | --- | --- |
| int/string/null  | Y  | Request ID, used to match the response to the corresponding request  |
| `method`  | string  | Y  | Request Method  |
| `params`  | object  | Y  | Request Parameter  |
  * `id` field can be any string, number, timestamp, etc., and is used to identify the request, and is returned in the response as is.
  * `method` field is the request method.
  * `params` field is the request parameters, according to the different request methods, the parameters are different, in any order.

#### Response Format[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#response-format "Permanent link")
WebSocket API requests must be transmitted in Json format in text frames, where a text frame message represents one request, example:
  * Success example：

```
{
"id": "2d812f20c9e1030f5551eab0e039f613",
"code": "0",
"msg": "success",
"data": "10000.00"
}

```

  * Failed example：

```
{
"id": "2d812f20c9e1030f5551eab0e039f613",
"code": "1",
"msg": "invalid symbol",
"data": null
}

```

**String Exmplaination**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| int/string/null  | Y  | Request ID  |
| `code`  | string  | Y  | Response code,"0" means success，others are error codes  |
| `msg`  | string  | Y  | Response descrtiption  |
| `data`  | object  | N  | Returns data, which varies depending on the request method and may be null  |
#### Authentication[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#authentication "Permanent link")
WebSocket API requests require authentication and need to include the following fields in all request parameters:
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| `apiKey`  | string  | Y  | API Key  |
| `timestamp`  | string  | Y  | Timestamp  |
| `nonce`  | string  | Y  | Random String  |
| `sign`  | string  | Y  | Signature String，Please refer to[Signature](https://www.bitunix.com/api-docs/spots/en_us/sign/#websocket-apiSigantureParameters)  |
#### Connection Test[¶](https://www.bitunix.com/api-docs/spots/en_us/ws/#connection-test "Permanent link")
WebSocket API connection test. The test can be performed in the following ways:

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "ping",
  "params": {
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
    }
}

```