---
title: "[源码阅读] Kubernetes 1.18 client-go (三) WorkQueue"
date: 2020-08-30T10:51:42+08:00
tags: ["golang", "kubernetes", "源码", "k8s"]
categories: ["golang", "源码", "kubernetes"]
draft: false
---

## 概览

在`kubernetes`的很多组件中，都会用到队列，为了方便使用，`client-go`中`k8s.io/client-go/util/workqueue`实现了通用的队列：

- 通用队列
- 延迟队列
- 限速队列

> `util/workqueue/doc.go`

```go
// Package workqueue provides a simple queue that supports the following
// features:
//  * Fair: items processed in the order in which they are added.
//  * Stingy: a single item will not be processed multiple times concurrently,
//      and if an item is added multiple times before it can be processed, it
//      will only be processed once.
//  * Multiple consumers and producers. In particular, it is allowed for an
//      item to be reenqueued while it is being processed.
//  * Shutdown notifications.
```

根据注释中的文档，它具有以下特性：

- 公平：元素是按照先进先出的顺序处理的
- 吝啬:一个元素不会被处理多次，并且即使一个元素被添加多次，也只处理一次
- 支持多个生产者和消费者， 并且允许处理中的元素重新入队
- 关闭通知

利用 Go 的接口组合，延迟队列和限速队列的接口定义，都是基于最基础的通用队列 的 interface：

> `util/workqueue/queue.go`

```go
type Interface interface {
    // 入队 将元素加入队尾
    Add(item interface{})
    // 队列长度
    Len() int
    // 出队 获取队列头部的元素
    Get() (item interface{}, shutdown bool)
    // 标记队列中该元素已经处理
    Done(item interface{})
    // 关闭队列
    ShutDown()
    // 查询队列是否关闭
	ShuttingDown() bool
}
```

可以用一个简单的类图来表示他们的 interface 和实现之间的关系
{{< mermaid >}}
classDiagram
class Interface{
<<interface>>
}

class DelayingInterface{
<<interface>>
}

class RateLimitingInterface{
<<interface>>
}

Interface o-- DelayingInterface : 组合
DelayingInterface o-- RateLimitingInterface : 组合

Type ..|>Interface:实现
delayingType..|>DelayingInterface:实现
rateLimitingType..|>RateLimitingInterface:实现
{{< /mermaid >}}

## 实现

### 通用队列

通用队列是最基础的队列，支持最基本的队列功能， 它实现了`workqueue.Interface`，它的结构如下

> `util/workqueue/queue.go`

```go
type Type struct {
    //基于slice来保证顺序，里面的元素应该在dirty set中，不应该在processing set中
	queue []t
    // 保存需要被处理的元素
    // set用于去重
	dirty set
    // 包含正在被处理的元素，他们同时也在dirty set,
    // 当处理完成后，他们会从processing set中被移除
    // 同时会检查是否在dirty set中，如果在，则将它加入queue中
	processing set
	cond *sync.Cond
    // 标识是否在关闭
	shuttingDown bool
    // 监控指标
	metrics queueMetrics

	unfinishedWorkUpdatePeriod time.Duration
	clock                      clock.Clock
}
```

首先先看下入队方法`Add`的实现，逻辑比较简单，正常的逻辑就是先加入`dirty set`，然后加入队列中;如果已经存在`dirty set`中则忽略，这就是前文中说到的`workqueue` **吝啬**的特性.；如果插入`dirty set`后发现正在处理中，则直接返回，因为在处理完调用`Done`时，会将`dirty set`中的元素重新加入队列.

```go
func (q *Type) Add(item interface{}) {
    //加锁
	q.cond.L.Lock()
    defer q.cond.L.Unlock()
    // 如果队列关闭中，则不再添加元素
	if q.shuttingDown {
		return
    }
    // 如果在dirty set中，则忽略
	if q.dirty.has(item) {
		return
	}

	q.metrics.add(item)

    //先插入dirty set中
    q.dirty.insert(item)
    // 如果 item正在处理，则忽略
	if q.processing.has(item) {
		return
	}
    //加入队列
    q.queue = append(q.queue, item)
    //发送广播，这样其他阻塞的Get协程就会继续
	q.cond.Signal()
}
```

在`Get`时,如果队列中没有元素且没有关闭，会一直阻塞直到有数据入队或者队列关闭;

```go
func (q *Type) Get() (item interface{}, shutdown bool) {
    //加锁
	q.cond.L.Lock()
    defer q.cond.L.Unlock()
    //如果队列中没有数据且没关闭，会阻塞,知道有元素加入队列
	for len(q.queue) == 0 && !q.shuttingDown {
		q.cond.Wait()
    }
    //如果没有数据，说明队列被关闭了
	if len(q.queue) == 0 {
		// 返回队列已经关闭
		return nil, true
	}

    //出队
	item, q.queue = q.queue[0], q.queue[1:]

	q.metrics.get(item)
    //将元素插入处理中
    q.processing.insert(item)
    //删除dirty中的元素
	q.dirty.delete(item)

	return item, false
}
```

`Done`将元素标记为处理完成，如果处理中却还在 dirty 中，则将它重新入队.正常的逻辑是处理完一个元素后，调用`Done`方法，会将`processing set`中的元素删除.根据`Add`的逻辑，如果在元素处理时`Add`，元素会被放入 `dirty set`中，这样在调用 `Done`时便会重新加入队列.

```go
func (q *Type) Done(item interface{}) {
    //加锁
	q.cond.L.Lock()
	defer q.cond.L.Unlock()

	q.metrics.done(item)
    //将它从proccess set删除
    q.processing.delete(item)
    // 如果出现在dirty set中,说明在处理的过程中又被添加了，则从新放回队列中
	if q.dirty.has(item) {
        q.queue = append(q.queue, item)
        //发送广播事件，通知关闭阻塞的Get方法
		q.cond.Signal()
	}
}
```

### 延时队列

从接口定义上看，延时队列除了通过接口组合拥有通用队列的全部方法，还多了一个 `AddAfter`方法：

> `util/workqueue/delaying_queue.go`

```go
type DelayingInterface interface {
	Interface
    //在经过一段时间后添加元素
	AddAfter(item interface{}, duration time.Duration)
}
```

`DelayingInterface`对应的实现则是`delayingType`,它的结构如下：

```go
type delayingType struct {
    //包含一个通用队列
	Interface
	// 用于获取时间
	clock clock.Clock
    // 通知结束的channel
	stopCh chan struct{}
    // stopOnce guarantees we only signal shutdown a single time
    // 确保只通知一次关闭
	stopOnce sync.Once
    // 心跳定时器，确保协程不会超过maxWait
	heartbeat clock.Ticker
    // waitingForAddCh is a buffered channel that feeds waitingForAdd
    // 用来缓冲延迟添加的元素，最大容量1000，超过将会阻塞
	waitingForAddCh chan *waitFor
    // 重试的监控指标
	metrics retryMetrics
}
```

既然延迟队列多了一个`AddAfter`方法，首先看一下`AddAfter`都做了什么：

```go
func (q *delayingType) AddAfter(item interface{}, duration time.Duration) {
    // 如果已经关闭则不再添加
	if q.ShuttingDown() {
		return
	}

	q.metrics.retry()

    // immediately add things with no delay
    // 如果延迟<=0则直接添加
	if duration <= 0 {
		q.Add(item)
		return
	}

	select {
            //当waitingForAddCh>1000时会被阻塞，所以这里读取stopChan确保在关闭时能正常退出
    case <-q.stopCh:
            //将数据写入缓冲channel
	case q.waitingForAddCh <- &waitFor{data: item, readyAt: q.clock.Now().Add(duration)}:
	}
}
```

既然在`AddAfter`往`waitingForAddCh`中发送数据，自然有地方去消费数据，那就是`waitingLoop`,它在初始化的时候创建 goroutine 调用：

```go
func (q *delayingType) waitingLoop() {
	defer utilruntime.HandleCrash()


	never := make(<-chan time.Time)

	var nextReadyAtTimer clock.Timer

    //初始化一个waitFor的优先级队列
	waitingForQueue := &waitForPriorityQueue{}
	heap.Init(waitingForQueue)

    //使用map来避免重复添加元素，如果重复可能会更新时间
	waitingEntryByData := map[t]*waitFor{}

	for {
        //如果队列关闭，则直接返回
		if q.Interface.ShuttingDown() {
			return
		}
        //获取当前时间
		now := q.clock.Now()

		// waitFor优先级队列中有数据
		for waitingForQueue.Len() > 0 {
            //获取优先级队列的第一个元素
            entry := waitingForQueue.Peek().(*waitFor)
            //如果还没到延迟的时间点，则跳出当前循环
			if entry.readyAt.After(now) {
				break
			}
            //取出第一个元素，放入队列中
			entry = heap.Pop(waitingForQueue).(*waitFor)
            q.Add(entry.data)
			delete(waitingEntryByData, entry.data)
		}

        // Set up a wait for the first item's readyAt (if one exists)

		nextReadyAt := never
		if waitingForQueue.Len() > 0 {

			if nextReadyAtTimer != nil {
				nextReadyAtTimer.Stop()
            }
            //优先级队列中的第一个肯定是最早ready的
            entry := waitingForQueue.Peek().(*waitFor)
            // 这个元素ready的时间
			nextReadyAtTimer = q.clock.NewTimer(entry.readyAt.Sub(now))
			nextReadyAt = nextReadyAtTimer.C()
		}

		select {
        case <-q.stopCh://如果队列关闭则退出循环
			return

        case <-q.heartbeat.C():// 定时器，每隔一段时间开始最外层循环


		case <-nextReadyAt: //元素ready了，继续循环，会将元素加入队列

        case waitEntry := <-q.waitingForAddCh://取出缓冲channel中的元素
            //时间没到
			if waitEntry.readyAt.After(q.clock.Now()) {
                //将元素放入优先级队列，插入或者更新前面定义的waitingEntryByData
                //这里需要注意的是如果添加的item已经重复了，使用的是最早ready的那个时间
				insert(waitingForQueue, waitingEntryByData, waitEntry)
			} else {
                //时间已经到了则直接放入队列
				q.Add(waitEntry.data)
			}
            //waitingForAddCh是带缓冲的，可能有多个元素
            //这里将他们都取出来出，处理逻辑和上面一样
			drained := false
			for !drained {
				select {
				case waitEntry := <-q.waitingForAddCh:
					if waitEntry.readyAt.After(q.clock.Now()) {
						insert(waitingForQueue, waitingEntryByData, waitEntry)
					} else {
						q.Add(waitEntry.data)
					}
				default:
					drained = true
				}
			}
		}
	}
}
```

这段代码中有使用到一个`waitForPriorityQueue`的优先级队列，它是基于二叉堆实现的，二叉堆是用来实现优先级队列的最常见的数据结构.优先级队列最主要的性质就是父节点的值总是大于(小于)或者等于它的每一个子节点的值，并且在取出数据或能够自动排序.

### 限速队列
