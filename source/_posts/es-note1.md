---
title: ElasticSearch系列学习-1
toc: false
thumbnail: /images/eagle.jpg
date: 2017-04-01 21:36:38
tags:
  - ElasticSearch
author: GSM
categories: 学习积累
---

_今天是一个要上班的愚人节_

整理自[ES.cn](http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/distrib-multi-doc.html)，并加入个人理解

## What is Elastic Search exactly?
ElasticSearch 是一个建立在全文搜索引擎Apache Lucene基础上的 __实时分布式搜索引擎__，而Lucene 是当今最先进，最高效的全功能开源搜索引擎框架。ElasticSearch降低了Lucene的学习和使用难度，用户可以使用ES统一的API即可进行全文检索，而不需了解Lucene背后原理。

<!-- more -->

<img src="https://static-www.elastic.co/assets/blt6050efb80ceabd47/elastic-logo%20(2).svg?q=891" alt="GitHub" title="GitHub,Social Coding" width="100" height="100" />

ES 脸谱

 - 基于Lucene，超越Lucene的搜索引擎
 - 海量数据实时分析
 - 分布式集群，易于扩展
 - 近似于数据库的聚合功能
 - 并非是一个全文检索系统.蜕变为一个完整的数据分析平台
 - Restful API
 - Json over HTTP

# Basic Concepts

__`ES节点`__ 是一个运行中的ES 实例。

__`ES集群`__ 包含一组节点，这些节点名字都是同一个cluster_name,他们一起工作并共享数据，还提供容错和可伸缩性。因此，ES可以横向扩展至数百甚至数千的服务器节点，同时可以处理PB级数据。<span style="color:red;">可以说，ES天生就是__分布式__的，并且在设计时屏蔽了分布式的复杂性。</span>

e.g.
~~~~~~html
http://localhost:9200/?pretty
{
  "name" : "gsm-node",
  "cluster_name" : "gsm-cluster",
  "cluster_uuid" : "gVeY2ENwTsmGY4wQgvoxXQ",
  "version" : {
    "number" : "5.2.2",
    "build_hash" : "f9d9b74",
    "build_date" : "2017-02-24T17:26:45.835Z",
    "build_snapshot" : false,
    "lucene_version" : "6.4.1"
  },
  "tagline" : "You Know, for Search"
}
~~~~~~

ES是 __`文档面向（file-oriented）`__ 的，对象在ES中的存储形式都为文件，并且采用
__`JSON`__ 作为文档的序列化格式。

__`索引和类型`__：一个ES集群可以包含很多 _索引_， 每个索引可以包含多个 _类型_ ，这些不同的类型存储着多个 _文档_ ，每个文档又有 多个 _属性_ 。类比于关系型数据库：
~~~~~~
数据库/表/行/属性 == 索引/类型/文档/属性
~~~~~~
当使用HTTP API 插入数据时候
~~~~~~
PUT /megacorp/employee/2
{
    "first_name" :  "Jane",
    "last_name" :   "Smith",
    "age" :         32,
    "about" :       "I like to collect rock albums",
    "interests":  [ "music" ]
}

the db is represented as megacorp
the table is represented as employee
2 is the line of employee
the http body, which is json document includes all the properties of line 2.
~~~~~~

__`索引和分片`__: Actually, __索引__ 实际上是指向一个或者多个物理 __分片（shard）__ 的 __逻辑命名空间__。 一个 __分片__ 是一个底层的 __工作单元__，是一个Lucene实例，它本身就是一个完整的搜索引擎。 在索引建立时候就已经确定了主分片数 [ why? ](#jump)，但是副分片数随时可以修改。

<img src="https://qbox.io/img/blog/elasticsearch_cluster.png?t=1439423553643&width=700" alt="Cluster" title="Cluster&Node" width="500" height="300" />

ES 利用分片将数据分发到集群内各个节点. 分片是数据的容器，文档保存在分片中。当集群扩大或者缩小，ES会自动在各个节点迁移分片，使数据均匀分布在集群中。当PUT一个document的时候，Elasticsearch通过对docid进行hash来确定其放在哪个shard上面，然后在shard上面进行索引存储。

当进行查询是，如果提供了查询的DocID，Elasticsearch通过hash就知道Doc存在哪个shard上面，再通过__routing table__查询就知道located哪个node上面，然后去node上面去取就好了。如果不提供DocID,那么Elasticsearch会在该Index（indics）shards所在的所有node上执行搜索预警，然后返回搜索结果，由coordinating node gather之后返回给用户
(哈希知分片。路由表知节点)

副分片是主分片的拷贝，用于灾备，搜索读服务。
下图分别：“集群只有一个节点，一个主分片存储P0，P1，P2三个文档的情况”，

![Shard](http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0202.png "One node, master shard and no copy shards assigned")

“集群有两个节点，一个主分片存储P0，P1，P2三个文档，每个主分片有一个副本分片的情况”，
![Shard](http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0203.png "Two nodes, master shards and copy shards")

“集群有三个节点，一个主分片存储P0，P1，P2三个文档，每个主分片有1个副本分片的情况”，
![Shard](http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0204.png "More nodes, master shards and copy shards")

Anyway, 分片是一个功能完整的搜索引擎，它拥有使用一个节点上的所有资源的能力。 我们这个拥有6个分片（3个主分片和3个副本分片）的索引可以最大扩容到6个节点，每个节点上存在一个分片，并且每个分片拥有所在节点的全部资源。

__`扩容`__：如果想扩容，使ES集群中的节点数增加，怎么办？

一个索引能存储多少数据量在索引创建的时候就已经确定下来了 -- 主分片数目在这时候已经确定。 但是，我们可以提高数据吞吐量，即增加replica shard的个数，因为replica shard 可以处理读操作，进行搜索并返回数据 。 But，当提高分片个数的时候，最好增加节点个数，否则每个分片从节点上获得的资源会更少。

更多副本分片处理索引

![Shard](http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0205.png "More replica shards").

当有一个节点宕机，通过副本分片机制来容灾
![Shard](http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0206.png "More replica shards").

[ES单机多实例部署方法](http://www.toutiao.com/i6362794212500439554/)

[Shards and replicas in ES](http://stackoverflow.com/questions/15694724/shards-and-replicas-in-elasticsearch/15705989#15705989)

# Interact with ElasticSearch

- 使用[Java API (9300)](https://www.elastic.co/guide/en/elasticsearch/client/index.html
)

分为 __节点客户端__ Node Client 和 __传输客户端__ Transport Client


- 使用Restful API with JSON over HTTP (9200)

API 格式
~~~~~~
curl -X<VERB> '<PROTOCOL>://<HOST>:<PORT>/<PATH>?<QUERY_STRING>' -d '<BODY>'
~~~~~~

# How a document is indexed？
一个 _对象_ 是基于特定语言的内存的数据结构。 为了通过网络发送或者存储它，我们需要将它表示成某种标准的格式。 _JSON_ 是一种以人可读的文本表示对象的方法。 __它已经变成 NoSQL 世界交换数据的事实标准__。当一个对象被序列化成为 JSON，它被称为一个 JSON 文档。

~~~~~~
object -> JSON document
~~~~~~
一个Employee JSON文档。
~~~~~~~~~
{
    "name":         "John Smith",
    "age":          42,
    "confirmed":    true,
    "join_date":    "2014-06-01",
    "home": {
        "lat":      51.5,
        "lon":      0.1
    },
    "accounts": [
        {
            "type": "facebook",
            "id":   "johnsmith"
        },
        {
            "type": "twitter",
            "id":   "johnsmith"
        }
    ]
}
~~~~~~~~~

通过使用index API, 文档可以被索引 -- 存储文档使之能够被搜索。
~~~~~
PUT /website/blog/123
{
  "title": "My first blog entry",
  "text":  "Just trying this out...",
  "date":  "2014/01/01"
}
~~~~~

这创建了低配版的索引，如果想自定义高配版（性能好）的索引，还需要自定义映射。

类似地，ES还提供`GET`, `HEAD`,`UPDATE`,`DELETE`等API.

当我们使用 index API 更新文档 ，可以一次性读取原始文档，做我们的修改，然后重新索引 整个文档 。 最近的索引请求将获胜：无论最后哪一个文档被索引，都将被唯一存储在 Elasticsearch 中。如果其他人同时更改这个文档，他们的更改将丢失。

在数据库领域中，有两种方法通常被用来确保并发更新时变更不会丢失。

<img src="http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0301.png" alt="concurrency" title="concurrency" width="300" height="500" />

- 悲观锁

    这种方法被关系型数据库广泛采用。It assumes 变更冲突时常发生，因此阻塞访问资源以防止冲突。一个典型的例子是读取一行数据之前先将其锁住，确保只有放置锁的线程能够对这行数据进行修改。

- 乐观锁

    Elasticsearch 中使用的这种方法假定冲突是不可能发生的，并且不会阻塞正在尝试的操作。 然而，如果源数据在读写当中被修改，更新将会失败。应用程序接下来将决定该如何解决冲突。 例如，可以重试更新、使用新的数据、或者将相关情况报告给用户。

ES通过`version`采用乐观锁的方式处理并发冲突。

ES 是__分布式__的。当文档创建、更新或删除 -- 【写操作】时， 新版本的文档必须复制到集群中的其他节点。Elasticsearch 也是__异步和并发__的，这意味着这些复制请求被并行发送，并且到达目的地时也许 顺序是乱的 -- `也解释了bulk 的api 格式`。

ES 需要一种方法确保文档的旧版本不会覆盖新的版本。这也是`version`的作用：确保应用中相互冲突的变更不会导致数据丢失。通过制定想要修改文档的`version`号来达到目的，如果该版本不是当前版本号，请求会失败。

所有文档的更新或删除 API，都可以接受 version 参数，这允许你在代码中使用乐观的并发控制，这是一种明智的做法。
~~~~~~
PUT /website/blog/1?version=1
{
  "title": "My first blog entry",
  "text":  "Starting to get the hang of this..."
}
~~~~~~
还有update API,  update API 简单使用与之前描述相同的 _检索-修改-重建索引_ 的处理过程。 区别在于这个过程发生在分片内部，这样就避免了多次请求的网络开销。通过减少检索和重建索引步骤之间的时间，我们也减少了其他进程的变更带来冲突的可能性。


# Distributed document storage
这一节讲的是上一章节的实现原理。

ES的主旨是随时可用和按需扩容。而扩容可以通过购买性能更强大（ 垂直扩容 ） 或者数量更多的服务器（水平扩容）来实现（垂直扩容有限，真正的扩容能力来自于水平扩容，__并且将负载压力和稳定性分散到这些节点中__）。ElastiSearch天生就是 __分布式__ 的 ，它知道如何通过管理多节点来提高扩容性和可用性。

如果想要实现分布式，需要回答下面两个问题：
~~~~~
1. 文档是如何被索引，进而物理上被存储在一个主分片中的？

2. ES是如何知道一个文档存在了哪个分片中的？
~~~~~

这个过程根据下面公式决定：

<pre class="literallayout">shard = hash(routing) % number_of_primary_shards</pre>
其中routing是一个变值，默认是文档的_id. <span id="jump">这就解释了为什么我们要在创建索引的时候就确定好主分片的数量 并且永远不会改变这个数量：因为如果数量变化了，那么所有之前路由的值都会无效，文档也再也找不到了。</span>

所有文档的API(get, index, delete, bulk, update, mget)都接受一个叫做`routing`的路由参数，通过路由参数我们可以自定义文档到分片的映射。`routing`确保了相关文档（所有隶属于同一个用户的文档）都被存储到同一个分片中。

## 写操作 CRUD

新建、索引和删除请求都是写操作。

<img src="http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0402.png" alt="GitHub" title="Write" width="500" height="200" />

Preliminaries: 每个节点都知道集群中任一文档位置[计算Hash查询，routing表]，所以可以直接将请求转发到需要的节点上。

以下是在主副分片和任何副本分片上面 成功新建，索引和删除文档所需要的步骤顺序：

1.客户端向 Node 1 发送新建、索引或者删除请求。

2.节点使用文档的 _id_ 确定文档属于分片 0`。请求会被转发到 `Node 3`，因为分片 0 的主分片目前被分配在 `Node 3 上。

3.Node 3 在主分片上面执行请求。如果成功了，它将请求并行转发到 Node 1 和 Node 2 的副本分片上。一旦所有的副本分片都报告成功, Node 3 将向协调节点报告成功，协调节点向客户端报告成功。

## 读操作 (已知doc Id的读，并非搜索的场景)

可以从master shard or replica shard检索文档。

<img src="http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0403.png" alt="GitHub" title="Read" width="500" height="200" />

以下是从主分片或者副本分片检索文档的步骤顺序：

1、客户端向 Node 1 发送获取请求。

2、节点使用文档的 _id_ 来确定文档属于分片 0 。分片 0 的副本分片存在于所有的三个节点上。 在这种情况下，它将请求转发到 Node 2 。

3、Node 2 将文档返回给 Node 1 ，然后将文档返回给客户端。

为了读取请求，协调节点在每次请求的时候将选择不同的副本分片来达到负载均衡；通过轮询所有的副本分片。

## 批量读and写
### mget
<img src="http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0405.png" alt="GitHub" title="mget" width="500" height="200" />

步骤:

1. client send `mget` to some node, such as Node1.

2. Node1 calculdate the shards where the ducuments in mget stored. Node1 为每个分片构建多文档请求，并将这些请求__并行__发送到每个参与的节点。（`一次发送多个文件，并行发送多个node`）

3. once getting all the response, Node1 will return them to client.

### bulk

<img src="http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0406.png" alt="GitHub" title="bulk" width="500" height="200" />

步骤:

1. client send `bulk` to some node, such as Node1.

2. Node1 calculdate the shards where the ducuments in mget stored. Node1为每个__节点__创建一个批量请求，并将这些请求__并发__转发到包含__主分片__的节点主机

3. 主分片一个接一个按顺序执行每个操作。当每个操作成功时，主分片并行转发新文档（或删除）到副本分片，然后执行下一个操作。 一旦所有的副本分片报告所有操作成功，该节点将向协调节点报告成功，协调节点将这些响应收集整理并返回给客户端。`主分片操作完，转发给副分片`

## 搜索
一个CRUD操作只对单个文档进行处理，文档的唯一性由 _index, _type, 和 routing values （通常默认是该文档的 _id ）的组合来确定。
 这表示我们确切的知道集群中哪个分片含有此文档。__搜索__需要一种更加复杂的执行模型，__因为我们不知道查询会命中哪些文档（并不知道文档ID）:这些文档有可能在集群的任何分片上__。一个 __搜索请求__ 必须询问我们关注的索引（index or indices）的所有分片的副本来确定它们是否含有任何匹配的文档。

搜索查询步骤：

step1: 客户端发送一个 search 请求到 Node 3(成为了 __协调节点__ ) ， Node 3 会创建一个大小为 from + size 的空优先队列

step2: Node 3 将查询请求转发到索引的每个主分片和副本分片中（ __广播__ 到每个分片copy, 这也是为什么增加分片copy可以增加搜索吞吐率）。每个分片在本地执行查询并添加结果到大小为 from + size 的本地有序优先队列中

step3：每个分片返回各自优先队列的轻量级结果列表：__仅包含结果文档的 ID 和排序值_score__ 给协调节点，也就是 Node 3 ，它合并这些值到自己的优先队列中来产生一个全局排序后的结果列表

<img src="http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0901.png" alt="GitHub" title="search" width="500" height="200" />

step4 协调节点辨别出哪些文档需要被取回(例如限制了from 90， size 10，那么最初90个会被丢弃)并向相关的分片提交多个 GET 请求（mget）。

step5 每个分片加载并 丰富 文档(加载文档的_source字段，如果有需要用highlight丰富结果文档。)，如果有需要的话，接着返回文档给协调节点。

step6 一旦所有的文档都被取回了，协调节点返回结果给客户端。

<img src="http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_0902.png" alt="GitHub" title="fetch" width="500" height="200" />

In a word, 当一个搜索请求被发送到某个节点时，这个节点就变成了__协调节点__。 这个节点的任务是__广播查询__请求到所有相关分片并将它们的响应整合成__全局排序__后的结果集合，这个结果集合会返回给客户端。

### 影响搜索过程的查询参数

#### 1. 偏好 preference
preference parameter allows you to set some determined shards or nodes to process query by yourself. 通过设置preference为一个特定任意值，比如用户会话ID，让用一个用户始终使用同一个分片，可以解决bouncing results（场景：查询结果按照timestamp排序，如果多个分片处理，每次查询不同分片的时间戳都不同，排序结果都不同）.

#### 2. 超时问题 timeout
搜索过程的短板：搜索花费的时间由最慢的分片的处理时间决定。如果一个节点有问题，就会导致所有的响应缓慢。

参数timeout 告诉分片允许处理数据的最大时间，如果没有在足够时间处理完所有数据，返回的查询结果可以是部分的，甚至是空数据。

    ...
    "timed_out":     true,  
    ...


这个搜索请求超时了。

#### 3. 路由 routing
在搜索的时候，不用搜索索引的所有分片，而是通过指定几个 routing 值来限定只搜索几个相关的分片：
~~~~~~~~~~~
GET /_search?routing=user_1,user2
~~~~~~~~~~~
这个技术在设计大规模搜索系统时就会派上用场

#### 4. 搜索类型 search type

缺省的搜索类型是 query_then_fetch 。 在某些情况下，你可能想明确设置 search_type 为 dfs_query_then_fetch 来改善相关性精确度：
~~~~~~~~~~~
GET /_search?search_type=dfs_query_then_fetch
~~~~~~~~~~~
搜索类型 dfs_query_then_fetch 有预查询阶段，这个阶段可以从所有相关分片获取词频来计算全局词频。

# High Performance

- 代价较小的批量操作：`mget`,`bulk`
  1. `mget` API 批量get多个文档
  2. `bulk` API 批量多次create, index, update , delete
![Shard](https://static1.squarespace.com/static/5783a7e19de4bb11478ae2d8/t/5821d2d509e1c467487375cf/1478614213586/bulk-_upload.png?format=750w "More replica shards").
- 单机多实例时, 配置主从分片在不同的机器; Shard不怕多，尽可能分散
- 避免深度分页的检索
- 优化映射，禁用 _all_
- 避免没有指定索引的检索和会差很多个索引的检索
~~~~~~~
整体高性能 = 每次查询的计算成本最小化 = 需要的节点尽量少 + 用到的Index尽量小
~~~~~~~