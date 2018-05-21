---
title: RocketMQ源码分析5--Client之Consumer模块
toc: true
banner: /images/cat2.jpeg
date: 2018-03-31 15:38:39
author: GSM
tags:
  - RocketMQ
categories: 中间件
---
本文是[RocketMQ源码分析系列](https://gsmtoday.github.io/tags/RocketMQ/)之五，如有疑问或者技术探讨，可以[email me](gsmuestc@163.com),欢迎探讨.

<!-- more -->

RocketMQ中Consuemer由用户部署，支持Push和Pull两种消费模式，支持集群消费和广播消息，提供实时的消息订阅机制。

Client模块的Producer和Consumer源码结构引用[此文的图](https://blog.csdn.net/chunlongyu/article/details/54585232)。
<img src="client.jpeg" width = "800" height = "600" align=center />

<img src="client-module.svg" width = "800" height = "600" align=center />

Producer和Consumer的共同逻辑，例如定期更新NameServer地址列表，定期更新TopicRoute，发送网络请求封装在MQClientInstance, MQClientAPIImpl, MQAdminImpl类。

## 集群消费，广播消息以及Pub/Sub
**Consumer Group**: Consumer的集合，这类Consumer通常消费一类消息，且消费逻辑一致。

**集群消费**: 一个Consumer Group重点Consumer实例平摊消费消息。例如，某个Topic有9条消息，其中一个Consumer Group有三个实例，那么每个实例只消费其中的三条消息。多个Consumer Group之间是Pub/Sub发布订阅模式。默认，Consumer是集群消费模式.

**广播消费**：一条消息被多个Consumer消费，即使这些Consumer属于同一个 Consumer Group消息也会被Consumer Group中的每个Consumer 都消费一次，广播消费中的 Consumer Group 概念可以认为在消息划分方面无意义。

```java
/**
 * Message model
 */
public enum MessageModel {
    /**
     * broadcast
     */
    BROADCASTING("BROADCASTING"),
    /**
     * clustering
     */
    CLUSTERING("CLUSTERING");

    private String modeCN;

    MessageModel(String modeCN) {
        this.modeCN = modeCN;
    }

    public String getModeCN() {
        return modeCN;
    }
}
```
## 消息的推和拉
RocketMQ是**以拉模式为主，兼有推模式**。

1.Push, 即Producer主动推送给Consumer: 发出消息到达broker后，broker马上把消息投递给Consumer.

客户端使用demo如下：
```java
DefaultMQPushConsumer consumer = new DefaultMQPushConsumer("consumeGroup_001");
        consumer.setNamesrvAddr("127.0.0.1:9876");
        consumer.subscribe("Propolinse", "*"); //subscribe a topic
        consumer.registerMessageListener(new MessageListenerConcurrently() {
            @Override
            public ConsumeConcurrentlyStatus consumeMessage(List<MessageExt> msgs,
                ConsumeConcurrentlyContext context) {
                System.out.println(Thread.currentThread().getName() + " Receive New Messages: " + msgs);
                return ConsumeConcurrentlyStatus.CONSUME_SUCCESS;
            }
        });
```

2.Pull，即Broker收到Producer生产的消息后什么也不做，只等着Consumer在需要消费消息时候，主动向Broker**拉取**消息。
客户端使用demo如下：
```java
 private static final Map<MessageQueue, Long> offsetTable = new HashMap<MessageQueue, Long>();

    public static void main(String[] args) throws InterruptedException, MQClientException {
        DefaultMQPullConsumer consumer = new DefaultMQPullConsumer("consumeGroup_002");
        consumer.setNamesrvAddr("127.0.0.1:9876");
        consumer.start();

        // 首先通过打算消费的Topic拿到对应的MessageQueue的集合
        Set<MessageQueue> mqs =consumer.fetchSubscribeMessageQueues("Propolinse"); 
        for (MessageQueue mq : mqs) {//遍历MessageQueue集合
            SINGLE_MQ:
            //针对每个MessageQueue批量取消息，一次取完后，记录该队列下一次要取的开始offset，直到取完了，再换另一个MessageQueue
            while (true) {
                try {
                    PullResult pullResult = consumer.pullBlockIfNotFound(mq, null, getMessageQueueOffset(mq), 32);
                    System.out.println(pullResult);
                    putMessageQueueOffset(mq, pullResult.getNextBeginOffset());

                    switch (pullResult.getPullStatus()) {
                        case FOUND:
                            List<MessageExt> messageExtList = pullResult.getMsgFoundList();
                            for (MessageExt m : messageExtList) {
                                System.out.println(new String(m.getBody()));
                            }
                            break;
                        case NO_MATCHED_MSG:
                            break;
                        case NO_NEW_MSG:
                            break SINGLE_MQ;
                        case OFFSET_ILLEGAL:
                            break;
                        default:
                            break;
                    }

                } catch (Exception e) {
                    e.printStackTrace();
                }
            }
        }
        consumer.shutdown();
    }

    private static void putMessageQueueOffset(MessageQueue mq, long offset) {
        offsetTable.put(mq, offset);
    }

    private static long getMessageQueueOffset(MessageQueue mq) {
        Long offset = offsetTable.get(mq);
        if (offset != null)
            return offset;
        return 0;
    }

```

实际上，在RocketMQ中无论是Push还是Pull, **底层都是通过Consumer从Broker拉消息实现的（PullAPIWrapper.pullKernelImpl）**。为了做到能够实时接收消息，RocketMQ使用长轮询方式，保证消息实时性和Push方式一致。这种长轮询类似Web QQ收发消息机制。

底层上看Consumer使用RocketMQ的client- pullMessage接口，通过remoting模块实现与Broker通信，调用pullMessageProcessor读取Broker存储的文件消息。
```java
PullResult pullResult = this.mQClientFactory.getMQClientAPIImpl().pullMessage(brokerAddr, requestHeader, timeoutMillis, communicationMode, pullCallback);
```
pullMessageProcessor 调用DefaultMessageStore读取消息：
```java
 final GetMessageResult getMessageResult =
            this.brokerController.getMessageStore().getMessage(requestHeader.getConsumerGroup(), requestHeader.getTopic(),
                requestHeader.getQueueId(), requestHeader.getQueueOffset(), requestHeader.getMaxMsgNums(), messageFilter);
```
Push方式里，consumer把轮询过程封装了，并注册MessageListener监听器，取到消息后，唤醒MessageListener的consumeMessage()来消费，对用户而言，感觉消息是被推送过来的。

Pull方式里，取消息的过程需要用户自己写，首先通过打算消费的Topic拿到MessageQueue的集合，遍历MessageQueue集合，然后针对每个MessageQueue批量取消息，一次取完后，记录该队列下一次要取的开始offset，直到取完了，再换另一个MessageQueue。

之所以采用Pull模式为主，是因为RocketMQ的主要应用场景是金融交易链路。因此需要将**稳定可靠**放在首位，因此采用了长连接轮询拉的模式。

### Push和Pull的使用场景
[https://cloud.tencent.com/document/product/406/4791](推荐)

- 场景1：Producer 生产速率 VS Consumer消费速率

如果Producer的生产速率大于Consumer消费速率, Push方式由于无法得知Consumer的状态，所以只要有数据产生，就会不断推送给Consumer一堆Consumer无法处理的消息，这时候Consumer只能不是reject就是error，然后来回踢皮球。

反观Pull模式，Consumer可以按需消费，不用担心自己处理不了的消息来骚扰自己，而broker堆积消息也会相对简单，无需记录每一个要发送消息的状态，只需要**维护所有消息的队列和偏移量**就可以了。所以对于慢消费，消息量有限且到来的速度不均匀的情况，Pull模式比较合适。 

- 场景2：消息的实时性

采用Push模式，一旦消息到达，服务端就会立刻将消息推送给Consumer,这种方式实时性是非常好的。
而Pull模式，如果想要保证实时性，就只能采用长连接轮询的方式去拉消息(RocketMQ就是如此)。

- 场景3：消息延迟与忙等

这是Pull模式最大的短板。由于主动权在消费方，消费方无法准确地决定何时去拉取最新的消息。如果一次Pull取到消息了还可以继续去Pull，如果没有Pull取到则需要等待一段时间重新Pull。但等待多久就很难判定了。你可能会说，我可以有xx动态Pull拉取时间调整算法，但问题的本质在于，有没有消息到来这件事情决定权不在消费方。也许1分钟内连续来了1000条消息，然后半个小时没有新消息产生，可能你的算法算出下次最有可能到来的时间点是31分钟之后，或者60分钟之后，结果下条消息10分钟后到了，是不是很让人沮丧？

当然也不是说延迟就没有解决方案了，业界较成熟的做法是从短时间开始（不会对broker有太大负担），然后指数级增长等待。比如开始等5ms，然后10ms，然后20ms，然后40ms……直到有消息到来，然后再回到5ms。

即使这样，依然存在延迟问题：假设40ms到80ms之间的50ms消息到来，消息就延迟了30ms，而且对于半个小时来一次的消息，这些开销就是白白浪费的。

在RocketMQ里，有一种优化的做法——长轮询 Pull ，来平衡推拉模型各自的缺点。基本思路是：消费者如果尝试拉取失败，不是直接return,而是把连接挂在那里wait,服务端如果有新的消息到来，把连接notify起来，这也是不错的思路。但海量的长连接block对系统的开销还是不容小觑的，还是要合理的评估时间间隔，给wait加一个时间上限比较好。

## 启动Consumer
<img src="clientboot.png" width = "800" height = "600" align=center />

## 引用
1. [RocketMQ客户端最佳实践](https://yq.aliyun.com/articles/66128?spm=a2c4e.11154837.601370.2.79df5db0SUbGbK)
2. OffsetStore
