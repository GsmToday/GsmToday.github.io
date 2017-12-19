---
title: Netty 是怎么做内存管理--PoolSubPage
banner: /images/tuboshu.jpg
date: 2017-08-27 11:20:30
author: NX
tags:
  - Netty
categories: Netty
---

## 初始化
PoolSubPage在页内进行内存分配，用位图记录内存分配的情况。
以默认的PageSize=8192byte为例，位图的大小被初始化为
long bitmap[] = new long[pageSize >>> 10]

<!-- more -->

简单说明一下，在Page中以16字节为最小单位划分内存段，而一个long类型的变量有64位，所以最多使用PageSize/16/64=8个
long型的变量就可以表示所有内存段。

假设我们以elemSize=72字节为单位，在页内进行内存段的划分，那最多将有maxNumElem=PageSize/elemSize=113个内存段。（elemSize一旦确定就不会改变， 页面中内存段都是大小一致的）
那么这113个内存段就要占用位图中113个位置，那需要多少个bitmap元素呢？

```
bitmapLength = maxNumElems >>> 6;
if ((maxNumElems & 63) != 0) {
    bitmapLength ++;
}
```

计算也比较简单，除64取整，如果存在不能整除的部分，结果再加1。当maxNumElems=113时，就需要2个数组元素来描述内存段的状态。
假如内存段更大到elemSize=4096，maxNumElems只有2时，就需要1个数据元素就可以描述着两个内存段。整个计算过程都基于位操作实现，效率更高。

## 分配流程
PoolSubPage分配内存段的过程就是在位图中找到第一个未被使用的内存段（marked as zero），返回一个描述其内存位置偏移量的整数句柄，用于定位。

代码如下：
```
private int findNextAvail() {
    final long[] bitmap = this.bitmap;
    final int bitmapLength = this.bitmapLength;
    for (int i = 0; i < bitmapLength; i ++) {
        long bits = bitmap[i];
        if (~bits != 0) {  //当前数组元素上有未分配的内存(marked as zero)
            return findNextAvail0(i, bits);
        }
    }
    return -1;
}
```
```
/**
  * i ：空闲内存在位图数组中的下标
  * bits : 数组元素表示的位图详情
  * return ：位图索引
  */
private int findNextAvail0(int i, long bits) {
    final int maxNumElems = this.maxNumElems;
    final int baseVal = i << 6; //高位用来记录分配的内存在位图数组中的下标位置

    for (int j = 0; j < 64; j ++) {
        if ((bits & 1) == 0) { //当前位置表示的内存未分配
            int val = baseVal | j; //低6位用来记录空闲内存在long型元素二进制表示中占据的位置
            if (val < maxNumElems) {
                return val;
            } else {
                break;
            }
        }
        bits >>>= 1; //右移，尝试下一位
    }
    return -1;
}
```

算法首先在位图数组bitmap中开始遍历，如果当前数组元素表示的内存空间上有空闲内存段(即数组元素的二进制位上有0)，则进一步在此数组元素中查找空闲内存段在二进制位上的位置。通过在二进制位上循环移位遍历，访问到0则构造内存偏移量并返回。整形的内存偏移量，低6位用来表示空闲内存在long型元素的二进制位表示中占据的位置，高位用来记录该数组元素的下标。

以下图的bitmap为例，算法首先在bitmap[0]上没有发现空闲内存，则进一步访问bitmap[1]。为了找到空闲内存在bitmap[1]中的位置，依次遍历，最终在位置2（j=2）上 找到目标内存。构建位图索引，baseVal = 1 << 6, val = baseVal | j = 01000010。

<div align = center>

![chunk example](subpage.jpg)  

</div>

```
final int bitmapIdx = getNextAvail();
int q = bitmapIdx >>> 6; //取数组元素的位置，即上述的baseVal
int r = bitmapIdx & 63; //相当于模64，计算得到上述算法流程中的变量j
assert (bitmap[q] >>> r & 1) == 0;
bitmap[q] |= 1L << r; //位图中相应的位置置1

if (-- numAvail == 0) {
    removeFromPool();
}

return toHandle(bitmapIdx);
```
```
private long toHandle(int bitmapIdx) {
    return 0x4000000000000000L | (long) bitmapIdx << 32 | memoryMapIdx;
}

```
当然，分配完成之后需要将位图中的位置置1，防止被再次分配。详细的过程已在代码中做了注释，不再详述。最终返回给Client的偏移量句柄，还需要做一次变化（toHandle），其结构也比较明显，句柄共占据long型的低48位，其中低32位记录当前内存页在PoolChunk的平衡二叉树中的节点编号，中间16位（低6位记录在位图long型元素的二进制位置，低3位记录在位图数组中的位置）。

## 上层调用
在 {% post_link poolchunk Netty 是怎么做内存管理-PoolChunk %} 一文中提到过，当用户请求的内存空间小于一个页面的内存大小时，会调用allocateSubpage在页面内进行内存分配。

看一下allocateSubpage的实现：
```
/**
 * Create/ initialize a new PoolSubpage of normCapacity
 * Any PoolSubpage created/ initialized here is added to subpage pool in the PoolArena that owns this PoolChunk
 *
 * @param normCapacity normalized capacity
 * @return index in memoryMap
 */
private long allocateSubpage(int normCapacity) {
    // Obtain the head of the PoolSubPage pool that is owned by the PoolArena and synchronize on it.
    // This is need as we may add it back and so alter the linked-list structure.
    PoolSubpage<T> head = arena.findSubpagePoolHead(normCapacity);
    synchronized (head) {
        int d = maxOrder; // subpages are only be allocated from pages i.e., leaves
        int id = allocateNode(d);
        if (id < 0) {
            return id;
        }

        final PoolSubpage<T>[] subpages = this.subpages;
        final int pageSize = this.pageSize;

        freeBytes -= pageSize;

        int subpageIdx = subpageIdx(id);
        PoolSubpage<T> subpage = subpages[subpageIdx];
        if (subpage == null) {
            subpage = new PoolSubpage<T>(head, this, id, runOffset(id), pageSize, normCapacity);
            subpages[subpageIdx] = subpage;
        } else {
            subpage.init(head, normCapacity);
        }
        return subpage.allocate();
    }
}

private int subpageIdx(int memoryMapIdx) {
    return memoryMapIdx ^ maxSubpageAllocs; // remove highest set bit, to get offset
}
```

首先根据在arena中找到normCapacity大小的内存空间应该在arena维持的PoolSubpage列表中的那一个节点上分配 (参见 {% post_link poolchunk Netty 是怎么做内存管理-PoolArena %}对内存结构的分析)，然后以d = maxorder, 在PoolChunk的完全二叉树中，寻找一个空闲的叶子节点，用于此次的内存分配。

在创建PoolChunk的是否会默认创建一个PoolSubpage的数组subpages=new PoolSubpage[1 << maxorder], 用来记录叶子节点被用作PoolSubpage的分配情况。在PoolChunk找到一个空闲的叶子节点时，首先调用subpageIdx，计算该叶子节点在PoolChunk完全二叉树最底层的相对位置。(完全二叉树最底层的第一页叶子节点编号为2<sup>maxorder</sup>, 所以任意叶子节点相对首个叶子节点的相对位置，可以通过上述代码中的异或运算，把高位的0抹掉，只保留低位的值即为相对位置)

如果subpages当前位置没有记录，则分配生产一个新的PoolSubpage对象，否则直接初始化当前PoolSubpage对象，并插入head的后。

最后调用allocate()就是执行前文所描述的页面内分配内存的执行流程。
