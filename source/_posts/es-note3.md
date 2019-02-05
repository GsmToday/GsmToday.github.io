---
title: Elastic Search 学习笔记-3 (深入了解ES搜索原理)
toc: false
thumbnail: /images/lu.jpg
date: 2017-04-12 22:47:09
tags:
  - ElasticSearch
categories: 中间件
author: GSM
---

We will not venture into Lucene's implementation details, but rather stick to how the inverted index
is used and built. That is what influences how we can search and index.

<!-- more -->

## inverted indexes and index terms
倒排索引将单词（terms）映射为包含该单词的文本。可以说，an index term is the unit of search. 由分词产生的terms直接决定哪些类型的搜索高效，哪些类型的搜索不高效。由于单词在倒排索引中是有序的，因此we can efficiently find the things given term __prefixes__.

When all we have is an inverted index, we want everything to look like a string prefix problem. -- ngram分词。
## building indexes
当创建一个倒排索引时候，有许多性能优化点要关注：`search speed`，`index compactness`, `indexing speed` and `the time it takes for new changes to become visible`.

`search speed`和`index compactness`是有关系的，

~~~~~~~
inverted index compatness(+) ->
data to be processed (-) ->
the data fit in memory(+) ->
the efficicency of update(-)
~~~~~~~
倒排索引被压缩地越小，要处理的数据就越小，进而可以放更多的数据到内存，这样查询速度也越快。但是，倒排索引被压缩程度越大，这也导致更新性能的牺牲。

事实上，ES的倒排索引写到硬盘之后是不变的（immutable）。这样便于并发处理，不需要加锁。而且一旦倒排索引被读入内存后，不需要再修改缓存，提高了查询性能。（因此，在Lucene存储经常变化的数据并不是一个好方法）

而在ES/Lucene中update a document 操作是先从索引中删除该document（删除是一个位图操作不算update），再重新插入该document。可见update操作是一个耗费资源的操作。there is no in-place update of values.

当新插入索引中一个文档的时候，索引的变化先被缓冲在内存中，最后一起flush to硬盘。 而什么时候flush to硬盘取决于 1. how quickly changes must be visble 2. 内存中可供缓存的容量 3. IO saturation.

## index update
既然倒排索引由于查询性能需要是不可变的，那么需要一个方法在保留不变形的前提下实现倒排索引的更新。
这也是索引分段的原因。

通过增加新的补充索引反映新近的修改，而不是重新写整个倒排索引。每个倒排索引都会被轮流查询到，
从最早的开发，查询完再对结果进行合并。

在per segment search基础上，Lucene introduce the concept of "commit point", 提交点列出所有
已知的文件.

逐段搜索会以如下流程进行工作：

1. 新文档被收集到内存索引缓存（ES与硬盘之间是文档系统缓存）， 见 Figure 1, “一个在内存缓存中包含新文档的 Lucene 索引” 。

2. 不时地, 缓存被提交 ：

    - 一个新的段--一个追加的倒排索引--被写入磁盘。

    - 一个新的包含新段名字的 提交点 被写入磁盘。

    - 磁盘进行 同步 — 所有在文件系统缓存中等待的写入都刷新到磁盘，以确保它们被写入物理文件。

3. 新的段被开启，让它包含的文档可见以被搜索。

4. 内存缓存被清空，等待接收新的文档。

<img src="http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_1102.png" alt="analyzer" title="analyzer" width="350" height="350" />
<img src="http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/images/elas_1103.png" alt="analyzer" title="analyzer" width="350" height="350" />

当一个查询被触发，所有已知的段按顺序被查询。词项统计会对所有段的结果进行聚合，以保证每个词和每个文档的关联都被准确计算。 这种方式可以用相对较低的成本将新文档添加到索引。

## Near real time search
之所以说ES，Lucene是近实时搜索，是因为upddates buffer flush to disk机制使得一个新的文档从索引到可被搜索的延迟显著降低了。而由于per-segment search按段搜索的发展，新文档在几分钟之内可被检索。

## index segments
Lucene中索引由多个不可改变的index segment/子索引组成。当新创建/更新一个文档, 索引先写到内存中缓冲着，触发一定限制条件后(flush)写入硬盘，生成一个独立的子索引 --  子索引在Lucene中叫做segment。当执行搜索的时候，Lucene在每个分段上执行搜索，过滤出所有删除，在所有分段上合并结果。每隔一段时间，这些segments会__触发一次合并__，被标记为删除的document会被抛弃，这也解释了为什么插入更多的document会导致a smaller index size.

Merge的触发： 通过配置mergefactor这个参数控制硬盘中有多少个segments. MergeFactor越大耗费内存越多，索引速度也会越快些。但太大譬如300，最后合并的时候还是很慢。Batch indexing 应 MergeFactor>10。

segments flush to disk最常见的原因是 “continuous index refreshing”(默认每秒refresh一次)。当segment被flush 到硬盘之后，这些更改的数据可以被搜索到，enables近实时搜索near real-time search.
~~~~
a flush = a new segment to be created + invalidate some caches + trigger a merge
~~~~

When indexing throughput is important, e.g. when batch (re-)indexing, it is not very productive to spend a lot of time flushing and merging small segments. Therefore, in these cases it is usually a good idea to temporarily increase the refresh_interval-setting, or even disable automatic refreshing altogether. One can always refresh manually, and/or when indexing is done.

但是，per-segment search 还有瓶颈-磁盘，一个新的文档更改形成新的段之后，需要linux文件操作`fsync`来确保被物理性地写入磁盘，这样在断电的时候就不会丢失数据。但是`fsync`操作代价很大，如果每次索引一个文档都去执行一次的话会造成很大的性能问题。

因此，ES将`fsync`从整个过程中移除，允许新段被写入和打开--使其包含的文档在未进行一次完整提交时便对搜索可见。 这种方式比进行一次提交代价要小得多，并且在不影响性能的前提下可以被频繁地执行。可以通过配置`refresh_interval`来配置新段在缓存中被打开--namely 在缓存中可以被搜索的概率。

refresh_interval 可以在既存索引上进行动态更新。 在生产环境中，当你正在建立一个大的新索引时，可以先关闭自动刷新，待开始使用该索引时，再把它们调回来：

PUT /my_logs/\_settings
{ "refresh_interval": -1 }

PUT /my_logs/\_settings
{ "refresh_interval": "1s" }
## elasticsearch indexes
以上讲的Lucene index, 现在让我们重回ES index. 一个ES index 由 若干主分片组成和若干副本组成。
每个分片都是一个Lucene index.
~~~~
a ElasticSearch index = {Lucene indexes}n = {index segments}n*m

ES index -> Lucene indexes -> Lucene index segments

n is # Lucene indexes
m is # index segments
~~~~
当你在ES索引上执行搜索的时候，最终搜索会落在所有segment上。所以可以说下面两个场景实质上是一样的：
~~~
1. search 2 ES index with 1 shard each
2. search 1 index with 2 shard
~~~

## Summary
To summarize, these are the important properties to be aware of when it comes to how Lucene builds, updates and searches indexes on a single node:

How we process the text we index dictates how we can search. Proper text analysis is important.
Indexes are built first in-memory, then occasionally flushed in segments to disk.
Index segments are immutable. Deleted documents are marked as such.
An index is made up of multiple segments. A search is done on every segment, with the results merged.
Segments are occasionally merged.
Field and filter caches are per segment.
Elasticsearch does not have transactions

## Reference:

1 . https://www.elastic.co/blog/found-elasticsearch-from-the-bottom-up
2 . http://elasticsearch.cn/book/elasticsearch_definitive_guide_2.x/dynamic-indices.html