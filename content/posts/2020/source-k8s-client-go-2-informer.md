---
title: "[源码阅读] Kubernetes 1.18 client-go (二) Informer机制的实现"
date: 2020-08-10T20:51:42+08:00
tags: ["golang", "kubernetes", "源码", "k8s"]
categories: ["golang", "源码", "kubernetes"]
draft: false
---

## 前言

在[前一篇文章](/source-k8s-client-go)中,我们对 client-go 中的 client 对象有了一定的了解，而在本文中，我们将去探究 Kubernetes 组件间的通信机制-`Informer`,它为 Kubernetes 的消息提供了实时性，可靠性和顺序性的保证。

<!--more-->

{{< admonition type=tip title="文中涉及代码及版本" open=true >}}

> ```shell
> git clone -b tags/kubernetes-1.18.6 https://github.com/kubernetes/client-go.git --depth=1
> ```
>
> {{< /admonition >}}

{{< admonition type=tip title="如涉及到编译和 Go 语言相关" open=true >}}

> ```shell
> ➜ go version
> go version go1.14.6 linux/amd64
> ```
>
> {{< /admonition >}}

## Informer 概览

在阅读代码之前，我们先用一段示例程序观察一下，`Informer` 都做了些什么？
{{< admonition type=example title="Informer示例" open=false >}}

> 源自《Kubernetes 源码剖析》

```go
package main

import (
	"log"
	"time"

	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {

	config, err := clientcmd.BuildConfigFromFlags("", "/home/yoyo/.kube/config")
	if err != nil {
		panic(err)
	}
	clinetset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err)
	}

	stopCh := make(chan struct{})
	defer close(stopCh)

    // 创建一个sharedInformer对象
	sharedInformers := informers.NewSharedInformerFactory(clinetset, time.Minute)
	// 通过sharedInformer创建一个监听Pod的Informer
	informer := sharedInformers.Core().V1().Pods().Informer()

	// 添加资源事件处理器
	informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			mObj := obj.(v1.Object)
			log.Printf("NewPod Add to Store: %s ", mObj.GetName())
		},
		UpdateFunc: func(oldObj, newObj interface{}) {
			oObj := oldObj.(v1.Object)
			nObj := newObj.(v1.Object)
			log.Printf("%s Pod Update to Store: %s", oObj.GetName(), nObj.GetName())
		},
		DeleteFunc: func(obj interface{}) {
			oObj := obj.(v1.Object)
			log.Printf("Pod Delete from Store: %s", oObj.GetName())
		},
	})
	informer.Run(stopCh)
}
```

{{< /admonition >}}

我们执行这个程序，并尝试随便创建和删除一个 pod，会发现，`informer` 能感知到 pod 的创建，更新，删除。

> `kubectl run -it --rm --restart=Never --image=youeclipse/blog test`

```shell
➜ go run informer.go
...
2020/08/18 23:39:21 NewPod Add to Store: test
...
2020/08/18 23:39:22 test Pod Update to Store: test
...
2020/08/18 23:40:08 Pod Delete from Store: test
```

`informer`是如何做到感知资源的变化的呢？带着这个问题，本文将深入源码，理解它的实现。

## SharedInformer

### SharedInformer 的定义

> `tools/cache/shared_informer.go`

`SharedInformer` 的定义是一个 interface，由接口的定义我们可以得知，它除了注册事件回调，还有对`apiserver`的缓存的功能。

```go
type SharedInformer interface {
	// 注册资源事件回调handler,并使用shared informer的重新同步周期
	// 当有资源变化就可以通知到使用者
	// 不同的事件的对于单个handler是依序处理的的，但是不同的handler之间是没有协同关系的
	AddEventHandler(handler ResourceEventHandler)
	// 注册资源事件回调handler，但是使用传入的重新同步周期
	AddEventHandlerWithResyncPeriod(handler ResourceEventHandler, resyncPeriod time.Duration)
	// 返回informer的Store,Store是一个interface,定义了sharedinformer的内部存储
	GetStore() Store
	// 返回informer的controller,1.18.6版本已经废弃
	GetController() Controller
	// informer的核心逻辑，当stopCh关闭的时候，返回
	Run(stopCh <-chan struct{})
	// 如果store已经全量同步了apisever的资源，则返回true
	HasSynced() bool
	//最近同步的资源的版本
	LastSyncResourceVersion() string
}
```

此外，这个文件还定义了`SharedIndexInformer`,它组合了`SharedInformer`,并新增了`Indexer`相关的操作,在实际创建`Informer`时，创建的就是`SharedIndexInformer`对应的实现，关于`Indexer`，后文也将详细介绍。

```go
type SharedIndexInformer interface {
	SharedInformer
	AddIndexers(indexers Indexers) error
	GetIndexer() Indexer
}
```

### Informer 的创建

在示例代码中，我们通过`informers.NewSharedInformerFactory`创建了一个`sharedInformerFactory`,然后通过`sharedInformerFactory` 创建了一个 pod 的`Informer`,所以我们从`sharedInformerFactory`入手，看看 pod 的`Informer`是如何创建的:

> `informers/factory.go`

`NewSharedInformerFactory`的返回值是 `SharedInformerFactory`， 它包含了一个`clientSet`,并实现了`SharedInformerFactory`接口。

```go
type sharedInformerFactory struct {
	//clientSet的interface
	client           kubernetes.Interface
	//命名空间
	namespace        string
	tweakListOptions internalinterfaces.TweakListOptionsFunc
	lock             sync.Mutex
	//默认的重新同步时间
	defaultResync    time.Duration
	//AddEventHandlerWithResyncPeriod 时自定义的重新同步时间
	customResync     map[reflect.Type]time.Duration
	// informerMap
	informers map[reflect.Type]cache.SharedIndexInformer
	// 用于查找已经start的informer，
	startedInformers map[reflect.Type]bool
}

```

接下来，示例在创建 pod 的 `Informer` 时，最终调用的是`sharedInformerFactory`的`InformerFor`

```go
func (f *sharedInformerFactory) InformerFor(obj runtime.Object, newFunc internalinterfaces.NewInformerFunc) cache.SharedIndexInformer {
	//涉及到map的修改，加锁
	f.lock.Lock()
	defer f.lock.Unlock()

	//如果已经创建过了，则返回，不在创建
	//这也就是为什么成为sharedInformer，同一个资源的Informer只
	//实例化一次，后续都复用同一个，可以减少对apiserver的压力
	informerType := reflect.TypeOf(obj)
	informer, exists := f.informers[informerType]
	if exists {
		return informer
	}

	//如果自定义了同步周期，则使用自定义的
	resyncPeriod, exists := f.customResync[informerType]
	if !exists {
		resyncPeriod = f.defaultResync
	}

	informer = newFunc(f.client, resyncPeriod)
	f.informers[informerType] = informer

	return informer
}
```

> `informers/core/v1/pod.go`

最终`InformerFor`会调用`defaultInformer`创建一个`podInformer`

```go

func (f *podInformer) Informer() cache.SharedIndexInformer {
	return f.factory.InformerFor(&corev1.Pod{}, f.defaultInformer)
}

```

### Informer 的核心逻辑

在创建一个 pod 的 Informer 后，我们调用了`Run`方法

> `tools/cache/shared_informer.go`

```go

func (s *sharedIndexInformer) Run(stopCh <-chan struct{}) {
	//处理panic
	defer utilruntime.HandleCrash()

	//创建一个DeltaFIFO
	fifo := NewDeltaFIFOWithOptions(DeltaFIFOOptions{
		KnownObjects:          s.indexer,
		EmitDeltaTypeReplaced: true,
	})

	cfg := &Config{
		Queue:            fifo,
		ListerWatcher:    s.listerWatcher,
		ObjectType:       s.objectType,
		FullResyncPeriod: s.resyncCheckPeriod,
		RetryOnError:     false,
		ShouldResync:     s.processor.shouldResync,

		Process: s.HandleDeltas,
	}
	//使用Config创建controller
	func() {
		s.startedLock.Lock()
		defer s.startedLock.Unlock()

		s.controller = New(cfg)
		s.controller.(*controller).clock = s.clock
		s.started = true
	}()


	//单独创建一个stopChan是因为processor必须要保证在controller stop之后再stop
	processorStopCh := make(chan struct{})
	var wg wait.Group
	defer wg.Wait()              // 等待processor stop
	defer close(processorStopCh) // 通知processor stop
	wg.StartWithChannel(processorStopCh, s.cacheMutationDetector.Run)
	wg.StartWithChannel(processorStopCh, s.processor.run)

	defer func() {
		s.startedLock.Lock()
		defer s.startedLock.Unlock()
		s.stopped = true // Don't want any new listeners
	}()
	s.controller.Run(stopCh)
}
```

在`Run`函数中，首先创建了一个 `DeltaFIFO`对象，并将它赋值给了`Config`对象的`Queue`字段，最后通过`cfg`的创建了`Controller`对象，而`Controller`对象则最终创建了`Reflector`并执行它的`Run`方法。
`DeltaFIFO`和`Reflector`是`Informer`相关的代码是实现`Informer`机制的的核心逻辑。

## Reflector

### Reflector 的定义

`Informer`通过`Reflector`监控资源变化的核心逻辑，当资源变化时，触发相应的变更事件。

```go
type Reflector struct {
	// 用来唯一标示Reflector，默认是 文件名:行号,是通过naming.GetNameFromCallsite获取的
	name string
	// Reflector类型，格式为gvk.Group + "/" + gvk.Version + ", Kind=" + gvk.Kind
	expectedTypeName string

	// 我们要缓存的资源类型,如果是非结构化(unstructured.Unstructured)的，apiVersion和kind都需要是正确的
	expectedType reflect.Type
	// The GVK of the object we expect to place in the store if unstructured.
	// 如果是非结构化的GVK对象，则需要赋值
	expectedGVK *schema.GroupVersionKind
	// Reflector的底层存储
	store Store
	// listerWatcher is used to perform lists and watches.
	// listerWatcher接口，处理list和wach的逻辑
	// 各种资源的Client都有实现Wath和List方法
	listerWatcher ListerWatcher

	// 重试机制相关，非gorutine安全
	backoffManager wait.BackoffManager
	// 重新同步周期
	resyncPeriod time.Duration

	ShouldResync func() bool
	clock clock.Clock

	// list的结果翻页
	paginatedResult bool
	// 最近同步的资源版本
	lastSyncResourceVersion string
	// 如果上次同步失败了就会是true
	isLastSyncResourceVersionUnavailable bool
	lastSyncResourceVersionMutex sync.RWMutex
	//需要注意的是 翻页的数据是直接从etcd读的 可能会影响性能
	WatchListPageSize int64
}
```

sharedIndexInformer

### Reflector 的核心逻辑

`Reflector`监控资源的核心逻辑是`ListAndWatch`，这里真正调用了`ListerWacher`的`List`和`Watch`方法，并做了很多优化，以减少对 apiserver 的压力。

```go
func (r *Reflector) ListAndWatch(stopCh <-chan struct{}) error {
	klog.V(3).Infof("Listing and watching %v from %s", r.expectedTypeName, r.name)
	var resourceVersion string

	options := metav1.ListOptions{ResourceVersion: r.relistResourceVersion()}

	if err := func() error {
		initTrace := trace.New("Reflector ListAndWatch", trace.Field{"name", r.name})
		defer initTrace.LogIfLong(10 * time.Second)
		var list runtime.Object
		var paginatedResult bool
		var err error
		listCh := make(chan struct{}, 1)
		panicCh := make(chan interface{}, 1)
		go func() {
			defer func() {
				if r := recover(); r != nil {
					panicCh <- r
				}
			}()
			//新建了一个pager对象，SimplePageFunc将资源的List函数转成带context的
			pager := pager.New(pager.SimplePageFunc(func(opts metav1.ListOptions) (runtime.Object, error) {
				return r.listerWatcher.List(opts)
			}))
			switch {
				//如果reflector设置了翻页参数，则赋值
			case r.WatchListPageSize != 0:
				pager.PageSize = r.WatchListPageSize
			case r.paginatedResult:
				//第一次就获取到了翻页的结果,只要对应的资源实现了翻页
			case options.ResourceVersion != "" && options.ResourceVersion != "0":
				//如果资源版本不为空且不等于0，就会去翻页获取，否则从缓存读取
				pager.PageSize = 0
			}

			list, paginatedResult, err = pager.List(context.Background(), options)
			if isExpiredError(err) || isTooLargeResourceVersionError(err) {
				r.setIsLastSyncResourceVersionUnavailable(true)
				//请求失败则重试
				list, paginatedResult, err = pager.List(context.Background(), metav1.ListOptions{ResourceVersion: r.relistResourceVersion()})
			}
			close(listCh)
		}()
		select {
		case <-stopCh:
			return nil
		case r := <-panicCh:
			panic(r)
		case <-listCh:
		}
		if err != nil {
			return fmt.Errorf("%s: Failed to list %v: %v", r.name, r.expectedTypeName, err)
		}

		if options.ResourceVersion == "0" && paginatedResult {
			r.paginatedResult = true
		}

		r.setIsLastSyncResourceVersionUnavailable(false) // list was successful
		initTrace.Step("Objects listed")
		listMetaInterface, err := meta.ListAccessor(list)
		if err != nil {
			return fmt.Errorf("%s: Unable to understand list result %#v: %v", r.name, list, err)
		}
		//获取资源版本号
		resourceVersion = listMetaInterface.GetResourceVersion()
		initTrace.Step("Resource version extracted")
		//将资源数据转成资源对象列表
		items, err := meta.ExtractList(list)
		if err != nil {
			return fmt.Errorf("%s: Unable to understand list result %#v (%v)", r.name, list, err)
		}
		initTrace.Step("Objects extracted")
		//替换store(DeltaFIFO)中的数据
		if err := r.syncWith(items, resourceVersion); err != nil {
			return fmt.Errorf("%s: Unable to sync list result: %v", r.name, err)
		}
		initTrace.Step("SyncWith done")
		//设置最新的版本号
		r.setLastSyncResourceVersion(resourceVersion)
		initTrace.Step("Resource version updated")
		return nil
	}(); err != nil {
		return err
	}

	resyncerrc := make(chan error, 1)
	cancelCh := make(chan struct{})
	defer close(cancelCh)
	go func() {
		//定时器，触发定时更新
		resyncCh, cleanup := r.resyncChan()
		defer func() {
			cleanup() // Call the last one written into cleanup
		}()
		for {
			select {
			case <-resyncCh:
			case <-stopCh:
				return
			case <-cancelCh:
				return
			}
			if r.ShouldResync == nil || r.ShouldResync() {
				klog.V(4).Infof("%s: forcing resync", r.name)
				// DeltaFIFO同步数据，
				if err := r.store.Resync(); err != nil {
					resyncerrc <- err
					return
				}
			}
			cleanup()
			resyncCh, cleanup = r.resyncChan()
		}
	}()

	for {
		// 让stopChan有可能去结束循环
		select {
		case <-stopCh:
			return nil
		default:
		}

		timeoutSeconds := int64(minWatchTimeout.Seconds() * (rand.Float64() + 1.0))
		options = metav1.ListOptions{
			ResourceVersion: resourceVersion,
			//超时设置
			TimeoutSeconds: &timeoutSeconds,
			// 类似于书签的开关
			//开启可以在watch重试的时候降低kube-apiserver的负载
			AllowWatchBookmarks: true,
		}


		start := r.clock.Now()
		w, err := r.listerWatcher.Watch(options)
		if err != nil {
			switch {
			case isExpiredError(err):

				klog.V(4).Infof("%s: watch of %v closed with: %v", r.name, r.expectedTypeName, err)
			case err == io.EOF:
				// 收到EOF说明watch结束
			case err == io.ErrUnexpectedEOF:
				klog.V(1).Infof("%s: Watch for %v closed with unexpected EOF: %v", r.name, r.expectedTypeName, err)
			default:
				utilruntime.HandleError(fmt.Errorf("%s: Failed to watch %v: %v", r.name, r.expectedTypeName, err))
			}

			// 如果返回 "connection refused" ,很大可能是apiserver没有返回
			// 后续将会restart重试
			if utilnet.IsConnectionRefused(err) {
				time.Sleep(time.Second)
				continue
			}
			return nil
		}
		//将事件通知到DeltaFIFO
		if err := r.watchHandler(start, w, &resourceVersion, resyncerrc, stopCh); err != nil {
			if err != errorStopRequested {
				switch {
				case isExpiredError(err):
					klog.V(4).Infof("%s: watch of %v closed with: %v", r.name, r.expectedTypeName, err)
				default:
					klog.Warningf("%s: watch of %v ended with: %v", r.name, r.expectedTypeName, err)
				}
			}
			return nil
		}
	}
}
```

``

## DeltaFIFO

### DeltaFIFO 的定义

> `tools/cache/store.go`

```go
type Store interface {
	Add(obj interface{}) error
	Update(obj interface{}) error
	Delete(obj interface{}) error
	List() []interface{}
	ListKeys() []string
	Get(obj interface{}) (item interface{}, exists bool, err error)
	GetByKey(key string) (item interface{}, exists bool, err error)
	Replace([]interface{}, string) error
	Resync() error
}
```

在上一节 Reflector 中，`Reflector`的核心逻辑都是围绕`Store`进行的，而`DeltaFIFO`则是`Store`的一个实现。

`DeltaFIFO`，顾名思义，FIFO 是一个先进先出的队列，Delta 在计算机的专业术语中一班理解为差异(增量)，在这里它是一个用来存放资源的变化。在`DeltaFIFO`的实现中,用 map 来存储实际的 Delta 数据，然后将 map 的 key 的放在队列中,相当于索引,这个结构和实现 `LRU` 用到的 `LinkedHashMap` 类似。

> `tools/cache/delta_fifo.go`

```go
type DeltaFIFO struct {
	// lock/cond用来保护items和queue
	// 防止并发读写
	lock sync.RWMutex
	cond sync.Cond
	//存放Delta的结构
	items map[string]Deltas
	//队列基于slice实现，存储key
	queue []string
	// 如果第一次插入的数据出队列了或者第一次被调用的是Delete/Add/Update方法
	populated bool
	// Replace第一次被调用的时候插入的Delta数量
	initialPopulationCount int
	//用来计算key的方法，类似于哈希函数
	keyFunc KeyFunc
	knownObjects KeyListerGetter
	//关闭的时候是true，用来在关闭的情况下跳出循环
	closed     bool
	closedLock sync.Mutex
	emitDeltaTypeReplaced bool
}
```

### DeltaFIFO 的关键逻辑

作为一个队列,`DeltaFIFO`必然是有生产者和消费者的，生产者(`Reflector`)调用`Add`方法,消费者(`Controller`)则调用`Pop方法`。

#### 生产者

在上一节`Reflector`的`ListAndWatch`方法中，最后调用了`watchHandler`，而`watchHandler`主要的逻辑就是调用`store`的`Add`,`Update`和`Delete`方法，而在`DeltaFIFO`的实现中，这三个方法的主要逻辑都在`queueActionLocked`函数

> `tools/cache/delta_fifo.go`

```go
func (f *DeltaFIFO) queueActionLocked(actionType DeltaType, obj interface{}) error {
	//通过资源对象获取key
	id, err := f.KeyOf(obj)
	if err != nil {
		return KeyError{obj, err}
	}
	//将对资源的操作放入Delta的map中
	newDeltas := append(f.items[id], Delta{actionType, obj})
	//对最近两次的操作去重
	newDeltas = dedupDeltas(newDeltas)


	if len(newDeltas) > 0 {
		//如果不存在，先将索引加入队列
		if _, exists := f.items[id]; !exists {
			f.queue = append(f.queue, id)
		}
		//更新实际的存储
		f.items[id] = newDeltas
		f.cond.Broadcast()
	} else {
		//这个逻辑实际上不会发生，作为一个兜底的逻辑
		delete(f.items, id)
	}
	return nil
}

```

#### 消费者

前面介绍了生产者，那么消费者是谁呢？在前文中阅读`controller`的`Run`函数，除了初始化`Reflector`,它还调用了`DeltaFIFO`的`processLoop`方法,在`processLoop`中不停地调用`Pop`方法消费。`Pop`接受一个`PopProcessFunc`方法，它是是消费者的核心逻辑

> `tools/cache/delta_fifo.go`

```go
func (f *DeltaFIFO) Pop(process PopProcessFunc) (interface{}, error) {
	f.lock.Lock()
	defer f.lock.Unlock()
	for {
		for len(f.queue) == 0 {
			//如果队列是空的，会阻塞直到有元素入队
			if f.IsClosed() {
				return nil, ErrFIFOClosed
			}

			f.cond.Wait()
		}
		//出队
		id := f.queue[0]
		f.queue = f.queue[1:]

		if f.initialPopulationCount > 0 {
			f.initialPopulationCount--
		}
		//根据key查找对应的Delta
		item, ok := f.items[id]
		if !ok {
			// Item may have been deleted subsequently.
			continue
		}
		//删除map中的对应元素
		delete(f.items, id)
		//调用传入的方法
		err := process(item)
		if e, ok := err.(ErrRequeue); ok {
			//如果出错且错误类型是ErrRequeue,重新入队
			f.addIfNotPresent(id, item)
			err = e.Err
		}
		// Don't need to copyDeltas here, because we're transferring
		// ownership to the caller.
		return item, err
	}
}
```

其中的`process`方法，实际上就是初始化`sharedIndexInformer`的`cfg`中的`HandleDeltas`方法

> `tools/cache/shared_informer.go`

```go
func (s *sharedIndexInformer) HandleDeltas(obj interface{}) error {
	s.blockDeltas.Lock()
	defer s.blockDeltas.Unlock()

	//从旧到新便利Delta数组
	for _, d := range obj.(Deltas) {
		switch d.Type {
		case Sync, Replaced, Added, Updated:
			s.cacheMutationDetector.AddObject(d.Object)
			//从本地缓存(indexer)获取，如果存在则更新
			if old, exists, err := s.indexer.Get(d.Object); err == nil && exists {
				if err := s.indexer.Update(d.Object); err != nil {
					return err
				}

				isSync := false
				switch {
				case d.Type == Sync:
					// Sync events are only propagated to listeners that requested resync
					//同步的时间只会通知给请求同步的listener
					isSync = true
				case d.Type == Replaced:
					if accessor, err := meta.Accessor(d.Object); err == nil {
						if oldAccessor, err := meta.Accessor(old); err == nil {
							isSync = accessor.GetResourceVersion() == oldAccessor.GetResourceVersion()
						}
					}
				}
				s.processor.distribute(updateNotification{oldObj: old, newObj: d.Object}, isSync)
			} else {
				if err := s.indexer.Add(d.Object); err != nil {
					return err
				}
				s.processor.distribute(addNotification{newObj: d.Object}, false)
			}
		case Deleted:
			if err := s.indexer.Delete(d.Object); err != nil {
				return err
			}
			s.processor.distribute(deleteNotification{oldObj: d.Object}, false)
		}
	}
	return nil
}

```

## 参考

[《Kubernetes 源码剖析》](https://weread.qq.com/web/reader/f1e3207071eeeefaf1e138akc81322c012c81e728d9d180)
