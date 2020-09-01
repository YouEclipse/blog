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
rateLimitingType ..|> RateLimitingInterface:实现

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
    //如果队列中没有数据且没关闭，会阻塞,直到有元素加入队列
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

这段代码中有使用到一个`waitForPriorityQueue`的优先级队列，它是基于二叉堆实现的，二叉堆是用来实现优先级队列的最常见的数据结构.优先级队列最主要的性质就是父节点的值总是大于(小于)或者等于它的每一个子节点的值，并且在取出或者添加数据或能够依然维持这个性质.

### 限速队列

限速队列主要用在一些需要重试的场景，根据错误的次数逐渐增加等待时间.从接口定义上看，限速队列在延时队列的基础上，新增了限速相关的功能：

> `util/workqueue/rate_limiting_queue.go`

```go
type RateLimitingInterface interface {
    //延时队列
	DelayingInterface

    // 限速之后添加一个元素
	AddRateLimited(item interface{})
    // 元素已经结束重试，无论是成功还是失败都会停止限速，这个元素会被抛弃
	Forget(item interface{})
    // 返回元素重新入队的次数
	NumRequeues(item interface{}) int
}

```

与之对应的实现则是`rateLimitingType`,

```go
type rateLimitingType struct {
	DelayingInterface

	rateLimiter RateLimiter
}
```

关于`rateLimitingType`,最重要的就是`rateLimiter`,它的定义也是个接口:

> `util/workqueue/default_rate_limiters.go`

```go
type RateLimiter interface {
    // 获取元素等待的时间
	When(item interface{}) time.Duration
    // 元素已经结束重试，无论是成功还是失败都会停止限速，这个元素会被抛弃
    Forget(item interface{})
    // 返回元素重新入队的次数
	NumRequeues(item interface{}) int
}
```

针对`RateLimiter`，client-go 中有五种基于不同算法的实现：

- BucketRateLimiter:令牌桶算法,基于`golang.org/x/time/rate`实现
- ItemBucketRateLimiter：令牌桶算法,与 BucketRateLimiter 的区别是每个元素使用独立的限速器
- ItemExponentialFailureRateLimiter：指数退避算法
- ItemFastSlowRateLimiter：计数器算法
- MaxOfRateLimiter:混合模式算法，多种限速算法混合使用

#### BucketRateLimiter

令牌桶算法是限流的最常见的算法那，它的原理就是系统以一个很定的速度往桶里放令牌，每当有一个元素需要加入队列，需要从桶里获得令牌，只有拥有令牌的元素才能入队，而没有令牌的元素，则只能等待。这样就能通过控制令牌的发放速率来控制入队的速率。

```go
type BucketRateLimiter struct {
	*rate.Limiter
}

func (r *BucketRateLimiter) When(item interface{}) time.Duration {
    //返回等待的时间
	return r.Limiter.Reserve().Delay()
}

func (r *BucketRateLimiter) NumRequeues(item interface{}) int {
    //不存在重新入队的情况
	return 0
}

func (r *BucketRateLimiter) Forget(item interface{}) {
    //没有重试机制
}
```

`BucketRateLimiter`简单封装了 go 官方开发的`golang.org/x/time/rate`包，调用`when`方法，`r.Limiter.Reserve().Delay()`返回等待时间.

#### ItemBucketRateLimiter

```go
type ItemBucketRateLimiter struct {
	r     rate.Limit
	burst int

	limitersLock sync.Mutex
	limiters     map[interface{}]*rate.Limiter
}
```

`ItemBucketRateLimiter`同样是基于`golang.org/x/time/rate`，与`ItemBucketRateLimiter`的区别是它是针对每个元素单独启用一个限流器.

#### ItemExponentialFailureRateLimiter

```go
type ItemExponentialFailureRateLimiter struct {
    failuresLock sync.Mutex
    //元素入队失败的次数
	failures     map[interface{}]int
    //最初的延迟
    baseDelay time.Duration
    //最大的延迟
	maxDelay  time.Duration
}
```

`ItemExponentialFailureRateLimiter`使用元素的入队失败次数作为指数，随着失败次数的增加,重新入队的等待间隔也越来越长，但不会超过 `maxDelay`.通过这种方式来限制相同元素的入队速率.其算法实现在`When`函数中：

```go
func (r *ItemExponentialFailureRateLimiter) When(item interface{}) time.Duration {
	r.failuresLock.Lock()
	defer r.failuresLock.Unlock()

    //获取当前元素的失败次数
	exp := r.failures[item]
	r.failures[item] = r.failures[item] + 1

    //计算指数 2^exp*baseDelay
    backoff := float64(r.baseDelay.Nanoseconds()) * math.Pow(2, float64(exp))
    //如果int64溢出了使用maxDelay
	if backoff > math.MaxInt64 {
		return r.maxDelay
	}

    calculated := time.Duration(backoff)
    // 超过了maxDelay也使用maxDelay
	if calculated > r.maxDelay {
		return r.maxDelay
	}

	return calculated
}
```

#### ItemFastSlowRateLimiter

```go
type ItemFastSlowRateLimiter struct {
    failuresLock sync.Mutex
    //失败次数
	failures     map[interface{}]int

    //快速重试的阈值
    maxFastAttempts int
    //短延迟
    fastDelay       time.Duration
    //长延迟
	slowDelay       time.Duration
}
```

`ItemFastSlowRateLimiter` 和`ItemExponentialFailureRateLimiter` 有些类似，它也是根据入队失败次数使用不同的延迟，只是在达到一定阈值(maxFastAttempts)前使用较低的延迟，在超过阈值后使用较高的延迟.它的实现如下：

```go

func (r *ItemFastSlowRateLimiter) When(item interface{}) time.Duration {
	r.failuresLock.Lock()
	defer r.failuresLock.Unlock()
    //错误次数+1
	r.failures[item] = r.failures[item] + 1
    //低于阈值使用短延迟
	if r.failures[item] <= r.maxFastAttempts {
		return r.fastDelay
	}

	return r.slowDelay
}
```

#### MaxOfRateLimiter

```go
type MaxOfRateLimiter struct {
	limiters []RateLimiter
}

```

`MaxOfRateLimiter`的结构是一个`RateLimiter`的 Slice，也就是说，它实际上可以使多种`RateLimiter`实现的组合，在`workqueue`包中`DefaultControllerRateLimiter`使用的就是`MaxOfRateLimiter`,需要注意的是，在调用`When`和`NumRequeues`时，他都是以其中的最大值为准，如`When`:

```go
func (r *MaxOfRateLimiter) When(item interface{}) time.Duration {
	ret := time.Duration(0)
	for _, limiter := range r.limiters {

        curr := limiter.When(item)
        //如果等待时间比上一个大，则使用当前的等待时间
        if curr > ret {
			ret = curr
		}
	}

	return ret
}
```

## 总结

通用队列，延迟队列和限速队列充分利用了 go 的接口和结构体组合的特性，并在实现过程中使用了队列，堆等基础的数据结构。通用队列的实现中使用`sync.cond`来唤醒等待的 goroutine 也值得学习，可以说 workqueue 非常好的利用 go 语言的特性与思想。

## 参考

[《Kubernetes 源码剖析》](https://weread.qq.com/web/reader/f1e3207071eeeefaf1e138akc81322c012c81e728d9d180)

[WorkQueue](https://www.qikqiak.com/k8strain/k8s-code/client-go/workqueue/#_1)
