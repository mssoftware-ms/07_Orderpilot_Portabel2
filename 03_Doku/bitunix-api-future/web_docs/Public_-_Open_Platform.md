---
content_hash: sha256:6be4bb41b072c5badc1aee4dae9830815d563e23facdf13066798d1d79939dbb
crawled_at: '2026-05-28T18:54:25.003082+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/spots/en_us/public/
tags:
- bitunix-api-future
- web-docs
title: Public - Open Platform
tool_used: crawl4ai
---

# Public
##  [Quick Start](https://www.bitunix.com/api-docs/spots/en_us/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#quick-start "Permanent link")
## Restful API[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#restful-api "Permanent link")
### Public Interface[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#public-interface "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#user-interface "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#order-interface "Permanent link")
## WebSocket API[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#websocket-api "Permanent link")
###  [WebSocket Introduction](https://www.bitunix.com/api-docs/spots/en_us/ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#websocket-introduction "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#public-interface_1 "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#user-interface_1 "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#order-interface_1 "Permanent link")
#### 1. Get latest price[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#1-get-latest-price "Permanent link")
> HTTP Requeset
> GET: /api/spot/v1/market/last_price
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| symbol  | string  | Y  | Pair  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | string  | N  | Last price  |
#### 2. Get depth data[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#2-get-depth-data "Permanent link")
> HTTP Request
> GET: /api/spot/v1/market/depth
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| symbol  | string  | Y  | Trading pair  |
| precision  | number  | Y  | token precision  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | Depth data  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| asks  | object[]  | N  | asks order depth  |
| bids  | object[]  | N  | bids order depth  |
| ts  | string  | N  | timestamp  |
asks/bids
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| price  | string  | N  | Price  |
| volume  | string  | N  | Size  |
#### 3. Get K-Line data[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#3-get-k-line-data "Permanent link")
> HTTP Request
> GET: /api/spot/v1/market/kline
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| symbol  | string  | Y  | Trading Pair  |
| interval  | string  | Y  | kline interval，Default is 1min(1,3,5,15,30,60,120,240,360,720,D,M,W)  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | K-Line data  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| symbol  | string  | N  | Trading pair  |
| open  | string  | N  | Open price  |
| high  | string  | N  | Highest price  |
| low  | string  | N  | Lowest price  |
| close  | string  | N  | Last price  |
| ts  | string  | N  | kline Starting timeISO8601  |
#### 4. Get K-Line history data[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#4-get-k-line-history-data "Permanent link")
> HTTP Request
> GET: /api/spot/v1/market/kline/history
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| symbol  | string  | Y  | Trading Pair  |
| interval  | string  | N  | kline interval，Default is 1min(1,3,5,15,30,60,120,240,360,720,D,M,W)  |
| endTime  | string  | N  | End timestamp (seconds), open interval, such as 1696507201. If not transmitted, it defaults to the current time and does not include the latest data  |
| limit  | string  | N  | Number of K-Line data, 1-500，Default is 200  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | K-Line data  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| symbol  | string  | N  | Trading pair  |
| open  | string  | N  | Open price  |
| high  | string  | N  | Highest price  |
| low  | string  | N  | Lowest price  |
| close  | string  | N  | Last price  |
| ts  | string  | N  | kline Starting timeISO8601  |
#### 5. Query trading pair data[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#5-query-trading-pair-data "Permanent link")
> HTTP Request
> GET: /api/spot/v1/common/coin_pair/list
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| Null  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object[]  | N  | Trading pair Data  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| id  | string  | N  | id  |
| base  | string  | N  | Base token  |
| quote  | string  | N  | Quote token  |
| basePrecision  | string  | N  | Base token precision  |
| quotePrecision  | string  | N  | Quote token precision  |
| minPrice  | string  | N  | Minimun trading amount  |
| minVolume  | string  | N  | Minimum trading volume  |
| isOpen  | string  | N  | Whether the pair is open or not  |
| isHot  | string  | N  | Whether the pair is trending or not  |
| isRecommend  | string  | N  | Whether the pair is recommended or not  |
| isShow  | string  | N  | Whether the pair is found or not  |
| tradeArea  | string  | N  | Trading categories  |
| sort  | string  | N  | Sorting order  |
| openTime  | string  | N  | Trading pair open time  |
| precisions  | string[]  | N  | Precesion of the trading pair  |
#### 6. Query rate data[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#6-query-rate-data "Permanent link")
> HTTP Request
> GET: /api/spot/v1/common/rate/list
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| Null  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object[]  | N  | Rate data  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| baseSymbol  | string  | N  | Base token  |
| quoteSymbol  | string  | N  | Quote token  |
| rate  | string  | N  | Rate  |
#### 7. Query token data[¶](https://www.bitunix.com/api-docs/spots/en_us/public/#7-query-token-data "Permanent link")
> HTTP Request
> GET: /api/spot/v1/common/coin/coin_network/list
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| Null  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object[]  | N  | Token data  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| name  | string  | N  | Token  |
| fullName  | string  | N  | Token full name  |
| logo  | string  | N  | Token icon  |
| track  | string  | N  | Categories  |
| quotePrecision  | string  | N  | Quote token precision  |
| minPrice  | string  | N  | Minumim order price  |
| isOpen  | string  | N  | Available for trading  |
| isHot  | string  | N  | Whether the token is trending  |
| depositOpen  | string  | N  | If deposit is open，0 means not，1 means deposit open；  |
| isShow  | string  | N  | Whether the token can be found  |
| withdrawOpen  | string  | N  | If withdrawal is open，0 means not, 1 means withdrawal open；  |
| withdrawMin  | string  | N  | Minimum withdrawal amount  |
| withdrawMax  | string  | N  | Maximum withdrawal amount  |
| networks  | object[]  | N  | Data of the the network of the token  |
networks
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| contractPrecision  | string  | N  | Token precision  |
| contractAddress  | string  | N  | Contract Address of the token  |
| requireMemo  | string  | N  | If memo is needed.0:No,1:Optional,2:Required  |
| chain  | string  | N  | Chain of the token  |
| depositConfirm  | string  | N  | How many blocks are needed for confirmation  |
| addressRegular  | string  | N  | Address regular verification  |
| network  | string  | N  | Name of Network  |
| isOpen  | string  | N  | Whether the network is open; 0:Close, 1:Open  |
| depositOpen  | string  | N  | If deposit is open，0 means not，1 means deposit open；  |
| isShow  | string  | N  | Whether the token can be found  |
| withdrawOpen  | string  | N  | If withdrawal is open，0 means not, 1 means withdrawal open；  |
| withdrawMin  | string  | N  | Minimum withdrawal amount  |
| withdrawMax  | string  | N  | Maximum withdrawal amount  |
| depositMin  | string  | N  | Minumum deposit amount  |

```
{
  "code": "0",
  "msg": "Success",
  "data": [
    {
      "name": "USDT",
      "fullName": "Tether",
      "logo": "https://image.xushidaifa.com/config/kv/358844.png",
      "track": "Metaverse",
      "isHot": 1,
      "isOpen": 1,
      "isShow": 1,
      "depositOpen": 1,
      "withdrawOpen": 1,
      "withdrawMin": "0",
      "withdrawMax": null,
      "networks": [
        {
          "contractPrecision": 6,
          "contractAddress": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
          "requireMemo": 0,
          "chain": "TRON",
          "depositConfirm": 20,
          "addressRegular": ".+",
          "network": "Tron (TRC-20)",
          "isOpen": 1,
          "isShow": 1,
          "depositOpen": 1,
          "withdrawOpen": 1,
          "withdrawMax": "3000000",
          "withdrawMin": "0.000001",
          "depositMin": "0.000001"
        }
      ]
    }
  ],
  "success": true
}

```