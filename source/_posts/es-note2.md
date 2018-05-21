---
title: Elastic Search 学习笔记-2 (搜索相关)
toc: false
banner: /images/squirrel.jpg
date: 2017-04-08 22:39:59
tags:
  - ElasticSearch
categories: 中间件
author: GSM
---

整理自[ES.cn](http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/distrib-multi-doc.html)，并加入个人理解

##  Search API

一种是 “轻量的” _查询字符串版本_ ，要求在查询字符串中传递所有的 参数。但是查询字符串参数需要URL编码

另一种是更完整的 _请求体版本_ ，要求使用 JSON 格式和更丰富的查询表达式作为搜索语言。（ES提供了DSL即领域特定语言）

<!-- more -->

### 轻量查询
[详见here](http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/_retrieving_a_document.html)，查询字符串版本更适合通过命令行做即席搜索。例如，查询在 tweet 类型中 tweet 字段包含 elasticsearch 单词的所有文档：
~~~~~~
GET /_all/tweet/_search?q=tweet:elasticsearch
~~~~~~

**_all查询：** 这个简单搜索返回包含 mary 的所有文档(从不同的字段中)：

~~~~~~
GET /_search?q=mary
~~~~~~

ES是如何做到的呢？当索引一个文档的时候, ES取出所有字段的值拼接成一个大的字符串，作为 _all_ 字段进行索引。

但是：

字符串搜索允许任何用户在索引的任意字段上执行可能较慢且重量级的查询，这可能会暴露隐私信息，甚至将集群拖垮。

因为这些原因，不推荐直接向用户暴露查询字符串搜索功能，除非对于集群和数据来说非常信任他们。

因此，在生产环境中更多地应该使用功能全面的请求体查询 request body query, API。

### 请求体查询
请求体查询的大部分参数是通过HTTP请求传递，而非查询字符串传递。

请求体查询 —下文简称 查询—不仅可以处理自身的查询请求，还允许你对<u>结果进行片段强调（高亮）</u>、对所有或部分结果进行<u>聚合分析</u>，同时还可以给出<u> 你是不是想找 的建议</u>，这些建议可以引导使用者快速找到他想要的结果。

请求体查询允许我们使用DSL 特定领域语言来书写查询语句。DSL是一种灵活且有表现力的查询语言，可以使查询语句更加灵活，精确。

DSL 的形式：
~~~~~~
GET /_search
{
    "query": YOUR_QUERY_HERE
}
~~~~~~

YOUR_QUERY_HERE是查询语句，典型结构为：
~~~~~~
{
    QUERY_NAME: {
        ARGUMENT: VALUE,
        ARGUMENT: VALUE,...
    }
}
~~~~~~

查询语句(Query clauses) 就像一些简单的组合块 ，这些组合块可以彼此之间合并组成更复杂的查询 -- 复合语句。一条复合语句可以将多条语句 — 叶子语句和其它复合语句 — 合并成一个单一的查询语句。

通过使用`bool`查询来实现将多查询组合成单一查询的查询方法。它接收以下参数：

`must`: 文档必须匹配这些条件才能被包含进来。

`must_not`: 文档 必须不 匹配这些条件才能被包含进来。

`should`: 如果满足这些语句中的任意语句，将增加 _score_ ，否则，无任何影响。
它们主要用于修正每个文档的相关性得分*。(全文匹配)

`filter`:
必须 匹配，但它以不评分、过滤模式来进行。这些语句对评分没有贡献，只是根据过滤标准来排除或包含文档。（精确匹配）

e.g. 评分缓存
~~~~~~~~~~~
下面的查询用于查找 title 字段匹配 how to make millions 并且不被标识为 spam 的文档。
那些被标识为 starred 或在2014之后的文档，将比另外那些文档拥有更高的排名。如果 _两者_ 都满足，那么它排名将更高：

{
    "bool": {
        "must":     { "match": { "title": "how to make millions" }},
        "must_not": { "match": { "tag":   "spam" }},
        "should": [
            { "match": { "tag": "starred" }},
            { "range": { "date": { "gte": "2014-01-01" }}}
        ]
    }
}
~~~~~~~~~~~

e.g. 不评分查询，有缓存
~~~~~~~
{
    "bool": {
        "must":     { "match": { "title": "how to make millions" }},
        "must_not": { "match": { "tag":   "spam" }},
        "should": [
            { "match": { "tag": "starred" }}
        ],
        "filter": {
          "range": { "date": { "gte": "2014-01-01" }}
        }
    }
}
~~~~~~~

By the way, validate-query API 可以用来验证查询是否合法, 并解释原因。
~~~~~
GET /gb/tweet/_validate/query?explain
{
   "query": {
      "tweet" : {
         "match" : "really powerful"
      }
   }
}
~~~~~

###　排序与相关性

#### 排序
计算_score的花销是巨大的，如果不使用相关性排序（例如filter操作）score为null.

e.g. 通过date排序。
~~~~~~~
  GET /_search
{
    "query" : {
        "bool" : {
            "filter" : { "term" : { "user_id" : 1 }}
        }
    },
    "sort": { "date": { "order": "desc" }}
}
~~~~~~~
查询结果_score : null

还可以实现多级排序。
假定我们想要结合使用 date 和 _score_ 进行查询，并且匹配的结果首先按照日期排序，然后按照相关性排序：
}
~~~~~~~
GET /_search
{
    "query" : {
        "bool" : {
            "must":   { "match": { "tweet": "manage text search" }},
            "filter" : { "term" : { "user_id" : 2 }}
        }
    },
    "sort": [
        { "date":   { "order": "desc" }},
        { "_score": { "order": "desc" }}
    ]
}
}
~~~~~~~

[字符串multifields -- 排序解决方案：在映射中增加子字段field](http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/multi-fields.html)

#### 计算相关性

相关性得分计算方法：

每一个子查询都独自地计算文档的相关性得分。一旦他们的得分被计算出来，bool查询就将
  这些得分进行合并并且返回一个代表整个bool 操作的得分。

Elasticsearch 的相似度算法 被定义为检索词频率/反向文档频率， `TF/IDF`.  `TF/IDF` (term frequency-inverse document frequency) 是一种用于信息检索和文本挖掘的常用加权技术。`TF/IDF`是一钟统计方法，用于评估一个word对于一个文件集或者一个语料库中其中一份文件的重要程度。

在ES中体现为：检索词的重要性随着它在**该字段**中出现的次数成正比增加，但同时会随着它在__索引__中出现的频率成反比下降, 并且与__字段长度__成反比。

`relevance = tf * idf * fieldNorm`

### 分页

和 SQL 使用 LIMIT 关键字返回单个 page 结果的方法相同，Elasticsearch 接受 from 和 size 参数：

__size__
显示应该返回的结果数量，默认是 10

__from__
显示应该跳过的初始结果数量，默认是 0

如果每页展示 5 条结果，可以用下面方式请求得到 1 到 3 页的结果：
~~~~~~
GET /_search?size=5
GET /_search?size=5&from=5
GET /_search?size=5&from=10
~~~~~~

# ES search, something deep

----
~~~~~~
映射（Mapping）
    描述数据在每个字段内如何存储(索引有哪些字段，字段什么数据类型，是否全文检索，用了哪个分析器)

分析（Analysis）
    全文是如何处理使之可以被搜索的(分词)

领域特定查询语言（Query DSL）
    Elasticsearch 中强大灵活的查询语言
~~~~~~
----

__精确值__，如它们听起来那样精确。例如日期或者用户 ID（在ES中 __`除了String类型的字段，都是精确查询的`__ ），但字符串也可以表示精确值，例如用户名或邮箱地址。对于精确值来讲，Foo 和 foo 是不同的，2014 和 2014-09-15 也是不同的。

精确值很容易查询。结果是二进制的：要么匹配查询，要么不匹配。这种查询很容易用 SQL 表示：
~~~~~~
WHERE name    = "John Smith"
  AND user_id = 2
  AND date    > "2014-09-15"
~~~~~~

__全文__ 是指文本数据（通常以人类容易识别的语言书写），例如一个推文的内容或一封邮件的内容。全文通常是指非结构化数据。

查询全文数据要微妙的多。我们问的不只是“这个文档匹配查询吗”，而是“ __该文档匹配查询的程度有多大__ ？”换句话说，__该文档与给定查询的相关性如何__ ？

我们很少对全文类型的域做精确匹配。相反，我们希望在文本类型的域中搜索。不仅如此，我们还希望搜索能够理解我们的 __意图__ ：
~~~~~
>搜索 UK ，会返回包含 United Kindom 的文档。

>搜索 jump ，会匹配 jumped ， jumps ， jumping ，甚至是 leap 。

>搜索 johnny walker 会匹配 Johnnie Walker ， johnnie depp 应该匹配 Johnny Depp 。

>fox news hunting 应该返回福克斯新闻（ Foxs News ）中关于狩猎的故事，同时， fox hunting news 应该返回关于猎狐的故事。
~~~~~
ES的搜索（search） 可以做到：

- 短语搜索，精准匹配一系列单词或者短语（match_phrase）
- 全文检索，找出所有匹配关键字的文档并按照相关性（relevance） 排序后返回结果。
- [高亮搜索功能](https://www.elastic.co/guide/en/elasticsearch/reference/master/search-request-highlighting.html)

__精确搜索VS全文搜索__：索引存储的字段分为代表 __精确值__ 的字段和代表 __全文__ 的字段。这个区别非常重要——它将搜索引擎和所有其他数据库区别开来。

例如，ES 可以为String 类型的字段指定 __映射__，在映射中设置哪些字段可以analyzed，该字段就支持全文检索；映射中设置哪些字段not analyzed,就支持精确检索。

## How full-text search works?

keyword: 分析和倒排索引，还有映射
~~~~~
index flow: prepare document -> analysis document to terms -> build inverted index -> save index to store

search flow: prepare query string -> analysis query to terms -> match inverted index -> return search result
~~~~~
为了促进全文搜索，Elasticsearch 首先 __分析__ 文档，之后根据结果创建 __倒排索引 __。__倒排索引__ 由文档中所有不重复词的列表构成，对于其中每个词，有一个包含它的文档列表。

倒排索引示例：

<img src="https://nlp.stanford.edu/IR-book/html/htmledition/img54.png" alt="inverted index" title="inverted index" width="500" height="600" />

之所以要__分析__，是因为ES是使用Lucene进行搜索，Lucene使用Analyzer分析器进行分析，将文本转换成可索引/可搜索的tokens(tokens可以理解为将一段文本，一篇文章打碎，分出一片片易于索引的单词)进行处理，分析包含下面的过程：

- 首先，将一块文本分成适合于倒排索引的独立的 _词条_。

- 之后，将这些词条统一化为标准格式以提高它们的 _可搜索性_

__分析器analyzer__ 执行分析工作。分词器由具体

1. 首先，字符串按顺序通过每个 `字符过滤器 char_filter`。他们的任务是在分词前整理字符串。一个字符过滤器可以用来去掉HTML，或者将 & 转化成 `and`。

2. 其次，字符串被`分词器 tokenizer`分为单个的词条。一个简单的分词器遇到空格和标点的时候，可能会将文本拆分成 __词条__。

3. 最后，词条按顺序通过每个 `token 过滤器 filter`。这个过程可能会改变词条（例如，小写化 Quick `Lowercase Tokenizer`
），删除词条（例如， 像 a，and， the 等无用词），或者增加词条（例如，像 jump 和 leap 这种同义词）

如图所示：
![](https://www.elastic.co/assets/blt51e787daed39eae9/Signatures.svg)

<img src="https://www.elastic.co/assets/bltee4e0b427d8fdad4/custom_analyzers_diag.png" alt="analyzer" title="analyzer" width="500" height="600" />

分词器Analyzer非常重要，因为他将document分成倒排索引(terms)，查询条件分成terms, 而直接影响了搜索命中率。

__创建一个自定义过滤器：__

格式
~~~~~~~
PUT /my_index
{
    "settings": {
        "analysis": {
            "char_filter": { ... custom character filters ... },
            "tokenizer":   { ...    custom tokenizers     ... },
            "filter":      { ...   custom token filters   ... },
            "analyzer":    { ...    custom analyzers      ... }
        }
    }
}
~~~~~~~
my_index索引创建example.
~~~~~~~~
PUT /my_index
{
    "settings": {
        "analysis": {
            "char_filter": {
                "&_to_and": {
                    "type":       "mapping",
                    "mappings": [ "&=> and "]
            }},
            "filter": {
                "my_stopwords": {
                    "type":       "stop",
                    "stopwords": [ "the", "a" ]
            }},
            "analyzer": {
                "my_analyzer": {
                    "type":         "custom",
                    "char_filter":  [ "html_strip", "&_to_and" ],
                    "tokenizer":    "standard",
                    "filter":       [ "lowercase", "my_stopwords" ]
            }}
}}}
~~~~~~~~

测试分析器
~~~~~~~
GET /my_index/_analyze?
{
  "analyzer":"my_analyzer"
  "text":"Text to analyze
}
~~~~~~~

结果中每个元素代表一个单独的词条：
~~~~~
{
   "tokens": [
      {
         "token":        "text",
         "start_offset": 0,
         "end_offset":   4,
         "type":         "<ALPHANUM>",
         "position":     1
      },
      {
         "token":        "to",
         "start_offset": 5,
         "end_offset":   7,
         "type":         "<ALPHANUM>",
         "position":     2
      },
      {
         "token":        "analyze",
         "start_offset": 8,
         "end_offset":   15,
         "type":         "<ALPHANUM>",
         "position":     3
      }
   ]
~~~~~

根据全文检索和精确检索的原理，也可以理解下面的搜索结果
~~~~~~~
GET /_search?q=2014-09-15        # 12 results !
GET /_search?q=2014              # 12 results
GET /_search?q=date:2014-09-15   # 1  result
GET /_search?q=date:2014-09-15   # 1  result
~~~~~~~
这是因为：当你查询一个 `全文域`时， 会对__查询字符串__应用相同的分析器，以产生正确的搜索词条列表。
但是当你查询一个 `精确值`域时，不会分析查询字符串，而是搜索你指定的精确值。

**那ES内部是怎么确定哪些域（属性）是全文域，哪些是精确域呢？**

ES将每个字段/域的数据类型保存在<span style="color:red;">__映射__</span>里。映射定义了索引的类型中有<span style="color:red;">哪些字段</span>，<span style="color:red;">字段的数据类型</span>，以及ES如何处理这些域，
<span style="color:red;">是属于全文域还是精确域</span>。例如String类型的域被ES默认地设置为全文域，
这样String类型的查询参数会用分析器分词。String也可以设置为not analysised, 这样就可以只进行精确匹配。因此，string 域映射的两个最重要 属性是 index 和 analyzer 。可以在index中指定是否被全文检索，在analyzer中指定分析器。

那么问题来了，映射是在什么时候进行配置的呢？-- 创建索引的时候。


## Important: Create and Manage your Index

通过put 一个文档的方法可以创建索引，这种方式采用的是默认的配置。例如：
~~~~
PUT /megacorp/employee/1
{
    "first_name" : "John",
    "last_name" :  "Smith",
    "age" :        25,
    "about" :      "I love to go rock climbing",
    "interests": [ "sports", "music" ]
}
~~~~
但是如果想要创建性能更高的索引，需要<span style="color:red;">`确保这个索引有数量适中的主分片`，`并且在索引任何数据之前，分析器和映射已经建立好。`</span>。 因此，需要手动创建索引。创建一个高配版的索引需要先创建好分词器和映射。

### Types and mapping of an index
类型在ES中表示一类相似的文档（类似sql的表）。类型由 _名称_ 和 _映射_ 组成。

其中，__映射mapping是基于index__ 的，所以一个index对应了一个映射，一个映射配置了这个index的所有类型. mapping 不仅仅指定了每个字段的类型，还可以指定这个字段能不能被检索，要不要被 __全文分析__，如果要被全文分析的话，要使用什么 __分析器__。（分析器用于将全文字符串分析拆分，转换为适合全文检索的倒排索引）.

映射描述了文档可能1. 具有的字段、2.每个字段的数据类型（string,integer,date）3.以及Lucene是如何索引和存储这些字段的。
#### Configure a type
对于String字段，两个最重要的映射参数是`index`和`analyzer`

index参数控制字符串以何种方式被索引。它包含以下三个值当中的一个：

|值 | 解释|
|------|------|
|analyzed|  首先分析这个字符串，然后索引。换言之，以全文形式索引此字段。|
|not_analyzed  |索引这个字段，使之可以被搜索，但是索引内容和指定值一样。不分析此字段。|
|no |  不索引这个字段。这个字段不能为搜索到。|

其他简单类型（long、double、date等等）也接受index参数，但相应的值只能是no和not_analyzed，它们的值不能被分析

analyzer字段指定哪一种分析器将在搜索和索引时候使用。默认ES使用standard分析器，也可以指定其他分析器。

举例：id字段被指定为精确匹配，name字段被指定为使用ngramAnalyzer分析器
~~~~~~~~
        "id":{
          "type":"keyword",
          "index":"not_analyzed"
        },
        "name":{
          "type":"text",
          "analyzer":"ngramAnalyzer",
          "search_analyzer":"whitespace"
        },
~~~~~~~~

#### root object of a mapping
映射的最高一层被称为 根对象。它包含

- 一个properties节点，列出了document中可能包含的每个字段的映射。

- 各种元数据字段，都以一个下划线开头，_type_ 、 _id_ 和 _source_ [metadata](https://www.elastic.co/guide/en/elasticsearch/reference/current/mapping-source-field.html)

- 配置项,控制如何动态处理新的字段，例如analyzer、 dynamic_date_formats 和 dynamic_templates

- 其他设置，可以同时应用在根对象和其他 object 类型的字段上，例如 enabled 、
dynamic 和 include_in_all

~~~~
 "mappings": {
    "staff":{
      "dynamic":"strict", // 动态映射，遇到新的字段就跑出异常
      "_all": { "analyzer": "ngramAnalyzer" },
      "properties":{
        "id":{
          "type":"keyword", // type表示字段的数据类型
          "index":"not_analyzed" //index表示字段是否应当被当成全文检索analyzed 或被当成一个准确的值（ not_analyzed ），还是完全不可被搜索（ no ）
        },
        "name":{
          "type":"text",
          "analyzer":"ngramAnalyzer",// index_analyzer确定在索引和搜索时全文字段使用的分析器
          "search_analyzer":"whitespace" //对搜索条件的分析器

        },
        ...
~~~~
###  dynamic mapping
当 Elasticsearch 遇到文档中以前 未遇到的字段，它用 dynamic mapping 来确定字段的数据类型并自动把新的字段添加到类型映射。

通过使用`dynamic_templates动态模板`,可以控制新检测生成字段的映射，甚至可以通过字段名称或者数据类型应用不同的映射。

模板按照顺序来检测；第一个匹配的模板会被启用。例如，我们给 string 类型字段定义两个模板：

es ：以 _es_ 结尾的字段名需要使用 spanish 分词器。
en ：所有其他字段使用 english 分词器。
我们将 es 模板放在第一位，因为它比匹配所有字符串字段的 en 模板更特殊：
~~~~~~~~~
PUT /my_index
{
    "mappings": {
        "my_type": {
            "dynamic_templates": [
                { "es": {
                      "match":              "*_es",
                      "match_mapping_type": "string",
                      "mapping": {
                          "type":           "string",
                          "analyzer":       "spanish"
                      }
                }},
                { "en": {
                      "match":              "*",
                      "match_mapping_type": "string",
                      "mapping": {
                          "type":           "string",
                          "analyzer":       "english"
                      }
                }}
            ]
}}}
~~~~~~~~~

### create an index
~~~~~~~~
PUT /my_index
{
    "settings": { ... any settings ... },
    "mappings": {
        "type_one": { ... any mappings ... },
        "type_two": { ... any mappings ... },
        ...
    }
}
~~~~~~~~


`settings` 指定这个索引多少个master shard, 多少个replica；刷新的ttl，自定义的分词器。

`mappings`是映射,定义了该类型都有哪些字段，该字段是什么数据类型，该字段使用是否被分析--全文检索，如果被分析，那么使用什么分析器。

索引创建示例, 创建一个索引由2个主分片，每个分片有1个副本分片构成；分析器是由{自定义hypen，auto_complete过滤器，分词器ngram_tokenizer}组成的{orgFullNameAnalyzer，ngramAnalyzer，phoneAnalyzer，phoneAnalyzer}，字段有{id,name,title,picture,phone,tel, gender, jobinfo}
~~~~
{
  "settings": {
    "index": {
      "number_of_shards":2,
      "number_of_replicas":1,
      "refresh_interval":"1s"
    },
    "analysis":{
      "filter":{
        "hypen":{
          "type":"stop",
          "stopwords":["-"]
        },
        "auto_complete":{
          "type":"edge_ngram",
          "min_gram":3,
          "max_gram":11
        }
      },
      "tokenizer":{
        "ngram_tokenizer": {
          "type":"ngram",
          "min_gram":3,
          "max_gram":10,
          "token_chars":["letter", "digit"]
        }
      },
      "analyzer": {
        "orgFullNameAnalyzer": {
          "type":"custom",
          "tokenizer":"ik_max_word",
          "filter":["lowercase", "hypen"]
        },
        "ngramAnalyzer": {
          "type":"custom",
          "tokenizer":"ngram_tokenizer",
          "filter":"lowercase"
        },
        "phoneAnalyzer": {
          "type":"custom",
          "tokenizer":"standard",
          "filter": "auto_complete"
        },
        "telAnalyzer": {
          "type":"custom",
          "tokenizer":"standard",
          "filter":["auto_complete","hypen"]
        }
      }
    }
  },
  "mappings": {
    "staff":{
      "dynamic":"strict",
      "_all": { "analyzer": "ngramAnalyzer" },
      "properties":{
        "id":{
          "type":"keyword",
          "index":"not_analyzed"
        },
        "name":{
          "type":"text",
          "analyzer":"ngramAnalyzer",
          "search_analyzer":"whitespace"
        },
        "title":{
          "type":"text",
          "analyzer":"ik_max_word",
          "search_analyzer":"whitespace"
        },
        "picture":{
          "type":"keyword",
          "index":"no"
        },
        "phone":{
          "type":"text",
          "analyzer":"phoneAnalyzer"
        },
        "tel":{
          "type":"text",
          "analyzer":"telAnalyzer"
        },
        "gender":{
          "type":"keyword",
          "index":"no"
        },
        "jobInfo":{
          "type":"text",
          "analyzer":"ik_max_word"
        }
      }
    }
  }
}
~~~~
[refer to 中文分词](http://www.itdadao.com/articles/c15a584262p0.html)


