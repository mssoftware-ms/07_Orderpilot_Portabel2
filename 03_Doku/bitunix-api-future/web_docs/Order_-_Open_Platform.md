---
content_hash: sha256:86e0e787c5423e8b84a22cd09a69dbefbd5178b2c62606957902f62ab2d3a0dd
crawled_at: '2026-05-28T18:54:25.030118+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/spots/en_us/order/
tags:
- bitunix-api-future
- web-docs
title: Order - Open Platform
tool_used: crawl4ai
---

# Order
##  [Quick Start](https://www.bitunix.com/api-docs/spots/en_us/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#quick-start "Permanent link")
## Restful API[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#restful-api "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#public-interface "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#user-interface "Permanent link")
### Order Interface[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#order-interface "Permanent link")
## WebSocket API[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#websocket-api "Permanent link")
###  [WebSocket Introduction](https://www.bitunix.com/api-docs/spots/en_us/ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#websocket-introduction "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#public-interface_1 "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#user-interface_1 "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#order-interface_1 "Permanent link")
#### 1. Place order[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#1-place-order "Permanent link")
> HTTP Request
> POST: /api/spot/v1/order/place_order
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| side  | number  | Y  | Side (1 Sell 2 Buy)  |
| type  | number  | Y  | Order Type(1:Limit 2:Market)  |
| volume  | string  | Y  | when put limit order, **volume** means quote coin's quantity, when put market order, **volume** means base coin's quantity  |
| price  | string  | Y  | Price  |
| symbol  | string  | Y  | Trading pair  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | Order details  |
Data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | Order ID  |
| side  | number  | Y  | Side (1 Sell 2 Buy)  |
| type  | number  | Y  | Order Type(1:Limit 2:Market)  |
| volume  | string  | Y  | when put limit order, **volume** means quote coin's quantity, when put market order, **volume** means base coin's quantity  |
| price  | string  | Y  | Price  |
| symbol  | string  | Y  | Trading pair  |
| placeStatus  | string  | Y  | Whether the order was successful or not, 1 Success  |
#### 2. Batch Order[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#2-batch-order "Permanent link")
> HTTP Request
> POST: /api/spot/v1/order/place_order/batch
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderList  | object[]  | Y  | Batch Order  |
orderList
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| side  | number  | Y  | Side (1 Sell 2 Buy)  |
| type  | number  | Y  | Order Type(1:Limit 2:Market)  |
| volume  | string  | Y  | when put limit order, **volume** means base coin's quantity, when put market order, **volume** means quote coin's quantity  |
| price  | string  | Y  | Price  |
| symbol  | string  | Y  | Trading pair  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object[]  | N  | Batch order details  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | Order ID  |
| side  | number  | Y  | Side (1 Sell 2 Buy)  |
| type  | number  | Y  | Order Type(1:Limit 2:Market)  |
| volume  | string  | Y  | Amount  |
| price  | string  | Y  | Price  |
| symbol  | string  | Y  | Trading pair  |
| placeStatus  | string  | Y  | Whether the order was successful or not, 1 Success  |
#### 3. Cancel order / Batch cancel[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#3-cancel-order-batch-cancel "Permanent link")
> HTTP Request
> POST: /api/spot/v1/order/cancel
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderIdList  | object[]  | Y  | Orders cancelled  |
orderIdList
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | Order ID  |
| symbol  | string  | Y  | Pairs  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  |
#### 4. Query matching orders[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#4-query-matching-orders "Permanent link")
> HTTP Request
> POST: /api/spot/v1/order/deal/list
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | Order ID  |
| symbol  | string  | Y  | Trading Pair  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | Order details  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| volume  | string  | Y  | Amount  |
| price  | string  | Y  | Price  |
| fee  | string  | Y  | Fee  |
| feeCoin  | string  | Y  | Token of fees  |
| role  | string  | Y  | Role(1-Maker 2-Taker)  |
| ctime  | string  | Y  | Filled time(ISO8601)  |
| id  | string  | Y  | Matching Order id  |
#### 5. Query order history[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#5-query-order-history "Permanent link")
> HTTP Request
> POST: /api/spot/v1/order/history/page
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| page  | number  | N  | Page number  |
| pageSize  | number  | N  | Display amount  |
| startTime  | string  | N  | Order creation starting time(ISO8601)  |
| endTime  | string  | N  | Order cereation ending time (ISO8601)  |
| status  | string  | N  | Order status（1 Unfilled,2 Filled,3 Partially filled,4 Cancelled,7 Partially filled/Canceled）  |
| side  | string  | N  | Side (1Sell2Buy)  |
| type  | string  | N  | Order type(1 Limit, 2 Market)  |
| symbol  | string  | Y  | Trading pair  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | Order details  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| total  | number  | Y  | Total number  |
| pageNum  | string  | Y  | Page number  |
| pageSize  | object  | N  | Items displayed  |
| data  | object[]  | N  | Order details  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | Order ID  |
| userId  | string  | Y  | UID  |
| orderType  | string  | Y  | Order type，1.Limit，2.Market  |
| amount  | string  | Y  | Total value (Quote token)  |
| dealAmount  | string  | Y  | Filled quantity  |
| volume  | string  | Y  | Filled value (Quote token)  |
| leftAmount  | string  | Y  | Remaining value (Quote token)  |
| volume  | string  | Y  | Order qty (Base token)  |
| dealVolume  | string  | Y  | Filled qty (Base token)  |
| leftVolume  | string  | Y  | Remaining qty (Base token)  |
| status  | string  | Y  | Order status（1 Unfilled,2 Filled,3 Partially filled,4 Cancelled,7 Partially filled/Canceled）  |
| type  | string  | Y  | 1.Limit，2.Market  |
| side  | string  | Y  | Side (1 Sell 2 Buy)  |
| price  | string  | Y  | Order price  |
| avgPrice  | string  | Y  | Avg price  |
| progress  | string  | Y  | Filled percentage Unit:1% 15.8 means 15.8%  |
| ctime  | string  | Y  | Order creation time  |
| utime  | string  | Y  | Order edit time  |
| base  | string  | Y  | Base token  |
| quote  | string  | Y  | Quote token  |
| symbol  | string  | Y  | Trading pair  |
| fee  | string  | Y  | Fee  |
| feeCoin  | string  | Y  | Token of fee  |
#### 6. Query current orders[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#6-query-current-orders "Permanent link")
> HTTP Request
> POST: /api/spot/v1/order/pending/list
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| symbol  | string  | Y  | Trading pair  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | Order details  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | Order ID  |
| userId  | string  | Y  | UID  |
| orderType  | string  | Y  | Order type，1.Limte，2.Market  |
| amount  | string  | Y  | Total value (Quote token)  |
| dealAmount  | string  | Y  | Filled qty  |
| volume  | string  | Y  | Filled value (Quote token)  |
| leftAmount  | string  | Y  | Remaining value (Quote token)  |
| volume  | string  | Y  | Order qty (Base token)  |
| dealVolume  | string  | Y  | Filled qty (Base token)  |
| leftVolume  | string  | Y  | Remaining qty (Base token)  |
| status  | string  | Y  | Order status（1 Unfilled,2 Filled,3 Partially filled,4 Cancelled,7 Partially filled/Canceled）  |
| type  | string  | Y  | 1.Limite，2.Market  |
| side  | string  | Y  | Side (1 Sell 2 Buy)  |
| price  | string  | Y  | Price  |
| avgPrice  | string  | Y  | Average price  |
| progress  | string  | Y  | Filled percentage Unit:1% 15.8 means 15.8%  |
| ctime  | string  | Y  | Order creation time  |
| utime  | string  | Y  | Order edit time  |
| base  | string  | Y  | Base token  |
| quote  | string  | Y  | Quote token  |
| symbol  | string  | Y  | Trading Pair  |
| fee  | string  | Y  | Fee  |
| feeCoin  | string  | Y  | Token of fee  |
#### 7. Query order detail[¶](https://www.bitunix.com/api-docs/spots/en_us/order/#7-query-order-detail "Permanent link")
> HTTP Request
> GET: /api/spot/v1/order/detail
**Parameters**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | order ID  |
**Returned Data**
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| code  | number  | Y  |
| msg  | string  | Y  | Description  |
| data  | object  | N  | Order details  |
data
| Name  | Type  | Required  | Notes  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | Order ID  |
| userId  | string  | Y  | UID  |
| orderType  | string  | Y  | Order type，1.Limte，2.Market  |
| amount  | string  | Y  | Total value (Quote token)  |
| dealAmount  | string  | Y  | Filled qty  |
| volume  | string  | Y  | Filled value (Quote token)  |
| leftAmount  | string  | Y  | Remaining value (Quote token)  |
| volume  | string  | Y  | Order qty (Base token)  |
| dealVolume  | string  | Y  | Filled qty (Base token)  |
| leftVolume  | string  | Y  | Remaining qty (Base token)  |
| status  | string  | Y  | Order status（1 Unfilled,2 Filled,3 Partially filled,4 Cancelled,7 Partially filled/Canceled）  |
| type  | string  | Y  | 1.Limite，2.Market  |
| side  | string  | Y  | Side (1 Sell 2 Buy)  |
| price  | string  | Y  | Price  |
| avgPrice  | string  | Y  | Average price  |
| progress  | string  | Y  | Filled percentage Unit:1% 15.8 means 15.8%  |
| ctime  | string  | Y  | Order creation time  |
| utime  | string  | Y  | Order edit time  |
| base  | string  | Y  | Base token  |
| quote  | string  | Y  | Quote token  |
| symbol  | string  | Y  | Trading Pair  |
| fee  | string  | Y  | Fee  |
| feeCoin  | string  | Y  | Token of fee  |