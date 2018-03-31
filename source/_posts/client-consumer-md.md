---
title: client-consumer.md
toc: false
banner: /images/
date: 2018-03-31 15:38:39
author:
tags:
---

先说说MQ的Push和Pull.
[引用自](https://my.oschina.net/xinxingegeya/blog/956370)
PullMessageProcessor
Rocket的消息订阅有两种模式 ： 
1. Push, 即消息的发送者生产消息后主动向消费者推送消息
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
2. Pull，即消息的消费者在需要消费消息时候，主动向Broker拉取消息。
```java
 private static final Map<MessageQueue, Long> offsetTable = new HashMap<MessageQueue, Long>();

    public static void main(String[] args) throws InterruptedException, MQClientException {
        DefaultMQPullConsumer consumer = new DefaultMQPullConsumer("consumeGroup_002");
        consumer.setNamesrvAddr("127.0.0.1:9876");
        consumer.start();

        Set<MessageQueue> mqs =consumer.fetchSubscribeMessageQueues("Propolinse"); // pull and subscribe a topic 
        for (MessageQueue mq : mqs) {
            SINGLE_MQ:
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

区别是[引用自](https://my.oschina.net/xinxingegeya/blog/956370)：Push方式里，consumer把轮询过程封装了，并注册MessageListener监听器，取到消息后，唤醒MessageListener的consumeMessage()来消费，对用户而言，感觉消息是被推送过来的。

Pull方式里，取消息的过程需要用户自己写，首先通过打算消费的Topic拿到MessageQueue的集合，遍历MessageQueue集合，然后针对每个MessageQueue批量取消息，一次取完后，记录该队列下一次要取的开始offset，直到取完了，再换另一个MessageQueue。

### 慢消费

慢消费无疑是Push模式最大的致命伤，如果消费者的速度比发送者的速度慢很多，势必造成消息在broker的堆积。假设这些消息都是有用的无法丢弃的，消息就要一直在broker端保存。当然这还不是最致命的，最致命的是broker给consumer推送一堆consumer无法处理的消息，consumer不是reject就是error，然后来回踢皮球。

反观Pull模式，consumer可以按需消费，不用担心自己处理不了的消息来骚扰自己，而broker堆积消息也会相对简单，无需记录每一个要发送消息的状态，只需要维护所有消息的队列和偏移量就可以了。所以对于慢消费，消息量有限且到来的速度不均匀的情况，pull模式比较合适。 

### 消息延迟与忙等

这是Pull模式最大的短板。由于主动权在消费方，消费方无法准确地决定何时去拉取最新的消息。如果一次Pull取到消息了还可以继续去Pull，如果没有Pull取到则需要等待一段时间重新Pull。但等待多久就很难判定了。你可能会说，我可以有xx动态Pull拉取时间调整算法，但问题的本质在于，有没有消息到来这件事情决定权不在消费方。也许1分钟内连续来了1000条消息，然后半个小时没有新消息产生，可能你的算法算出下次最有可能到来的时间点是31分钟之后，或者60分钟之后，结果下条消息10分钟后到了，是不是很让人沮丧？

当然也不是说延迟就没有解决方案了，业界较成熟的做法是从短时间开始（不会对broker有太大负担），然后指数级增长等待。比如开始等5ms，然后10ms，然后20ms，然后40ms……直到有消息到来，然后再回到5ms。

即使这样，依然存在延迟问题：假设40ms到80ms之间的50ms消息到来，消息就延迟了30ms，而且对于半个小时来一次的消息，这些开销就是白白浪费的。

在RocketMQ里，有一种优化的做法——长轮询 Pull ，来平衡推拉模型各自的缺点。基本思路是：消费者如果尝试拉取失败，不是直接return,而是把连接挂在那里wait,服务端如果有新的消息到来，把连接notify起来，这也是不错的思路。但海量的长连接block对系统的开销还是不容小觑的，还是要合理的评估时间间隔，给wait加一个时间上限比较好。

