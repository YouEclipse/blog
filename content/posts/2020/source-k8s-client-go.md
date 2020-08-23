---
title: "[源码阅读] Kubernetes 1.18 client-go (一) 深入理解 Client 对象"
date: 2020-08-06T21:31:42+08:00
tags: ["golang", "kubernetes", "源码", "k8s"]
categories: ["golang", "源码", "kubernetes"]
draft: false
---

## 前言

近期在做`Kubernetes`和`Istio`微服务治理的落地项目，随着项目的推进，working on learning，对于`Kubernetes`和`Istio`算是入了门。机缘巧合之下，加入了[云原生社区](https://cloudnative.to/)的 Kubernetes 源码研习社，一起学习 kubernetes 源码,希望能对于 Kubernetes 有更加深入的理解。
<!--more-->

本系列文章将参考郑东旭老师《Kubernetes 源码剖析》一书的目录结构阅读。

{{< admonition type=tip title="文中涉及代码及版本为" open=true >}}

> ```shell
> git clone -b tags/kubernetes-1.18.6 https://github.com/kubernetes/client-go.git --depth=1
> ```
{{< /admonition >}}

{{< admonition type=tip title="如涉及到编译和 Go 语言相关" open=true >}}


> ```shell
> ➜ go version
> go version go1.14.6 linux/amd64
> ```
{{< /admonition >}}

## 概览

我们在使用 Go 基于 k8s 做二次开发时，`client-go`是必不可少的依赖库,它封装了所有 与`kube-apiserver`交互的操作，可以理解成 `kube-apiserver` 的 sdk。

> 在我们拉取 kubernetes 主仓库源码时,在`vendor/k8s.io` 目录下有一个 client-go,这个 `client-go` 是通过 `git subtree` 方式引用 [kubernetes/client-go](https://github.com/kubernetes/client-go) 的,从历史提交记录来看，我猜测它应该在在`go moudle`诞生之前作为 vendor 依赖包用的,而目前 kubernetes 已支持 `go module`,`go.mod` 中则通过`replace`引用 `staging/`目录下的`k8s.io/client-go`,stage 目录下的该包会定时同步到 [kubernetes/client-go](https://github.com/kubernetes/client-go)。不过，这些都不重要，无论哪里的代码，只要是同一个版本，其实都是一样的代码。

我们在阅读源码之前,我们熟悉下 client-go 的目录结构

```shell
➜ tree -d  -L 1
.
├── deprecated // 要废弃的代码
├── discovery // DiscoveryClient 相关，用于发现kube-apiserver所支持的资源组，资源版本，资源信息
├── dynamic // DynamicClient 相关，用于
├── examples // client-go 的一些example
├── Godeps  // 使用 Godep 作为包管理时的相关文件
├── informers // 每种 kubernetes 资源的 Informer 的实现
├── kubernetes // ClientSet 相关,包含了所有group的client
├── kubernetes_test // 只包含有一个超时的单元测试函数，一个很奇怪的目录
├── listers // 为每个 Kubernetes 资源提供的 Lister功能，该功能对 Get 和 List 请求提供只读的缓存数据
├── metadata //GVR的interface定义
├── pkg // 包含一些导出的
├── plugin // 提供一些云厂商插件
├── rest // RestClient，封装了基础的 restful 操作
├── restmapper
├── scale // ScaleClient，用于deployment、replicaSet等资源的扩缩容
├── testing // 测试相关的包
├── third_party //第三方包，目前只是包含了从go标准库`text/template`中的部分私有代码
├── tools
├── transport //提供安全的TCP连接，支持http Stream,用于一些需要传输二进制流的场景，例如exec,attach等操作
└── util //工具包，包含 WorkQueue 工作队列，Certificate证书等操作
```

## Client 对象

`k8s.io/client-go` 中有几个最重要的 Client 对象

- RestClient
- DiscoveryCient
- Clientset
- DynamicClient

他们提供了各种与`kube-apiserver`交互的功能，本文也将主要阅读这几个 Client 的源码

### RestClient

> `rest/client.go`

```go
type RESTClient struct {
    // net/url对象,可以方便地处理url的scheme,host,path,query等
    base *url.URL

    // url中的vxxx,比如v1/
	versionedAPIPath string

    // 包含序列化和反序列化的配置,比如配置Content-Type来设置body时返回yaml或者json
	content ClientContentConfig

    // RestClient的重试机制,BackoffManager 是一个interface
    // 默认是不带Backoff的，可以自己实现重试机制，
    // 或者用rest包中自带的URLBackoff，它使引用flowcontrol包中
    // 基于指数退避算法的Backoff
	createBackoffMgr func() BackoffManager

    // 限流器，作用于所有使用RestClient实例化的对象发起的请求
    // 它是一个interface，可以自己写一个实现该接口的限流器，
    // 当然也可以用flowcontrol包中实现的令牌桶限流tokenBucketRateLimiter,
    // 它使用golang.org/x/time/rate实现
	rateLimiter flowcontrol.RateLimiter

    // 如果想使用自己定制的http.Client,赋值给它就行
    // 如果是nil，那么将使用默认的http.DefaultClient
	Client *http.Client
}
```

`k8s.io/client-go/rest` 包的`RestClient` 基于 Go 标准库封的`http.Client`封装了 RESTful API 相关约定的实现，所有对于 `kube-apiserver` 的 RESTful 请求都基于 `RestClient`,它实现了`rest.Interface`:

```go
type Interface interface {
	GetRateLimiter() flowcontrol.RateLimiter
	Verb(verb string) *Request
	Post() *Request
	Put() *Request
	Patch(pt types.PatchType) *Request
	Get() *Request
	Delete() *Request
	APIVersion() schema.GroupVersion
}
```

实际上，client-go 中基于 `RestClient` 的 Client,都是基于 `rest.Interface` 而不是 RestClient 本身,理论上你可以自己实现一个 RestClient 来替代,这也充分体现了 Go 语言提倡的面向接口编程的思想。`rest.Interface`的定义本身没啥难以理解的，但是其中`Verb`函数返回的`Request`却值得一看:

> `rest/request.go`

```go

type Request struct {
	c *RESTClient

    //限流器
    rateLimiter flowcontrol.RateLimiter
    //重试机制
    backoff     BackoffManager
    //超时
	timeout     time.Duration

	verb       string
	pathPrefix string
	subpath    string
	params     url.Values
	headers    http.Header

	namespace    string
	namespaceSet bool
	resource     string
	resourceName string
	subresource  string

	// output
	err  error
	body io.Reader
}
```

`Request`这个结构封装了大量的函数用来构造 request 来实际发起 http 请求，为了方便地使用链式调用，把不同函数的参数甚至 err 都放在了`Request`结构中, `RestClient`的一些初始化操作也放在了`NewRequest`的时候,比如`rateLimiter`和`backoff`。Request

```go
func (r *Request) request(ctx context.Context, fn func(*http.Request, *http.Response)) error {
	// 监控指标收集
	start := time.Now()
	defer func() {
		metrics.RequestLatency.Observe(r.verb, r.finalURLTemplate(), time.Since(start))
	}()

	if r.err != nil {
		klog.V(4).Infof("Error in request: %v", r.err)
		return r.err
	}

	if err := r.requestPreflightCheck(); err != nil {
		return err
	}

    //如果client为空，使用http.DefaultClient
	client := r.c.Client
	if client == nil {
		client = http.DefaultClient
	}


    // 避免一个超时的请求被限流
	if err := r.tryThrottle(ctx); err != nil {
		return err
	}

    //超时处理
	if r.timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, r.timeout)
		defer cancel()
	}

    // 如果返回了Retry-After，重试10次
	maxRetries := 10
	retries := 0
	for {

		url := r.URL().String()
		req, err := http.NewRequest(r.verb, url, r.body)
		if err != nil {
			return err
		}
		req = req.WithContext(ctx)
		req.Header = r.headers

		r.backoff.Sleep(r.backoff.CalculateBackoff(r.URL()))
		if retries > 0 {
            // 重试的请求也会被限流
			if err := r.tryThrottle(ctx); err != nil {
				return err
			}
		}
		resp, err := client.Do(req)
		updateURLMetrics(r, resp, err)
		if err != nil {
			r.backoff.UpdateBackoff(r.URL(), err, 0)
		} else {
			r.backoff.UpdateBackoff(r.URL(), err, resp.StatusCode)
		}
		if err != nil {

            //重试只针对GET方法，因为其他方法不是幂等的
			if r.verb != "GET" {
				return err
			}
            // 连接错误或者apiserver宕机才会重试
			if net.IsConnectionReset(err) || net.IsProbableEOF(err) {
                // 通过返回Retry-After来控制重试
				resp = &http.Response{
					StatusCode: http.StatusInternalServerError,
					Header:     http.Header{"Retry-After": []string{"1"}},
					Body:       ioutil.NopCloser(bytes.NewReader([]byte{})),
				}
			} else {
				return err
			}
		}

		done := func() bool {
            // 确保response body 被读完且关闭，这样才能复用TCP连接
            // 参考http.Client源码https://github.com/golang/go/blob/master/src/net/http/client.go#L698
			defer func() {
				const maxBodySlurpSize = 2 << 10
				if resp.ContentLength <= maxBodySlurpSize {
					io.Copy(ioutil.Discard, &io.LimitedReader{R: resp.Body, N: maxBodySlurpSize})
				}
				resp.Body.Close()
			}()

			retries++
			if seconds, wait := checkWait(resp); wait && retries < maxRetries {
				if seeker, ok := r.body.(io.Seeker); ok && r.body != nil {
					_, err := seeker.Seek(0, 0)
					if err != nil {
						klog.V(4).Infof("Could not retry request, can't Seek() back to beginning of body for %T", r.body)
						fn(req, resp)
						return true
					}
				}

				klog.V(4).Infof("Got a Retry-After %ds response for attempt %d to %v", seconds, retries, url)
				r.backoff.Sleep(time.Duration(seconds) * time.Second)
				return false
			}
			fn(req, resp)
			return true
		}()
		if done {
			return nil
		}
	}
}
```

### DiscoveryClient

> `discovery/discovery.go`

```go

type DiscoveryClient struct {
	restClient restclient.Interface

	LegacyPrefix string
}
```

`k8s.io/client-go/discovery`包中的 `DiscoveryClient` 是用来发现 Kubernetes 所支持的 GVR(Group,Resource,Version)的，它核心的的结构也是一个`rest.Interface`，同时，他也实现了`DiscoveryInterface`:

```
type DiscoveryInterface interface {
    //返回底层restClient
	RESTClient() restclient.Interface
	ServerGroupsInterface
	ServerResourcesInterface
	ServerVersionInterface
	OpenAPISchemaInterface
}

```

可以看到它是由多个接口`组合`而成,不难看出就是 GVR 相关的接口。文件中还有一个带缓存的 DiscoverClient 的接口定义`CachedDiscoveryInterface`，它基于`DiscoveryInterface`组合而成，具体在 `client-go/discovery/disk`和`client-go/discovery/memory`中各有一个实现，一个基于磁盘，另一个则基于内存。

> `discovery/cached/disk/cached_discovery.go`

```go
type CachedDiscoveryClient struct {
	delegate discovery.DiscoveryInterface

    // 缓存目录，每个host:port都是唯一的
	cacheDirectory string

	// 缓存TTL
    ttl time.Duration

    // 防止并发读写
	mutex sync.Mutex

    // ourFiles are all filenames of cache files created by this process
    // 该实例创建的所有缓存的文件名
	ourFiles map[string]struct{}
	// 如果为true则所有缓存文件失效
	invalidated bool
	// 如果都为true则所有缓存文件都是有效的
	fresh bool
}

```

`CachedDiscoveryClient`从磁盘读取缓存的逻辑在`getCachedFile`

```go
func (d *CachedDiscoveryClient) getCachedFile(filename string) ([]byte, error) {
    // after invalidation ignore cache files not created by this process
    // 如果缓存失效,或则没有缓存，返回err
	d.mutex.Lock()
	_, ourFile := d.ourFiles[filename]
	if d.invalidated && !ourFile {
		d.mutex.Unlock()
		return nil, errors.New("cache invalidated")
	}
	d.mutex.Unlock()

	file, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer file.Close()
    //获取缓存文件的描述信息
	fileInfo, err := file.Stat()
	if err != nil {
		return nil, err
	}
    //缓存是否过期
	if time.Now().After(fileInfo.ModTime().Add(d.ttl)) {
		return nil, errors.New("cache expired")
	}

    //缓存有效则从文件读取
	cachedBytes, err := ioutil.ReadAll(file)
	if err != nil {
		return nil, err
	}

	d.mutex.Lock()
	defer d.mutex.Unlock()
	d.fresh = d.fresh && ourFile

	return cachedBytes, nil
}
```

> `discovery/cached/disk/round_tripper.go`

另外，`CachedDiscoveryClient` 还封装了 Go 原生的`http.RoundTripper`,支持了符合[HTTP 标准](https://tools.ietf.org/html/rfc7234)的 HTTP cache,需要在程序启动时指定 `--cache-dir` flag。

> `discovery/cached/memory/memcache.go`

```go
type memCacheClient struct {
	delegate discovery.DiscoveryInterface

    //  防止并发读写map
    lock                   sync.RWMutex
    // response缓存在map
    groupToServerResources map[string]*cacheEntry
    // 缓存group
    groupList              *metav1.APIGroupList
    // 缓存是否有效
	cacheValid             bool
}
content/posts/2020/go-ddd-micro_services.md
```

`memCacheClient`则是使用内存来缓存的,缓存的核心逻辑是`refreshLocked`，主要用于更新缓存

```go
func (d *memCacheClient) refreshLocked() error {
	//获取所有的ResourceGroup
	gl, err := d.delegate.ServerGroups()
	if err != nil || len(gl.Groups) == 0 {
		utilruntime.HandleError(fmt.Errorf("couldn't get current server API group list: %v", err))
		return err
	}

    wg := &sync.WaitGroup{}
	resultLock := &sync.Mutex{}
	rl := map[string]*cacheEntry{}
	for _, g := range gl.Groups {
		for _, v := range g.Versions {
			gv := v.GroupVersion
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer utilruntime.HandleCrash()

				r, err := d.serverResourcesForGroupVersion(gv)
				if err != nil {
					utilruntime.HandleError(fmt.Errorf("couldn't get resource list for %v: %v", gv, err))
				}
                //因为是并发去更新map，所以需要加锁保护
				resultLock.Lock()
				defer resultLock.Unlock()
				rl[gv] = &cacheEntry{r, err}
			}()
		}
	}
    wg.Wait()

    //指针赋值是原子的无需加锁
	d.groupToServerResources, d.groupList = rl, gl
	d.cacheValid = true
	return nil
}
```

`k8s.io/client-go/discovery` 包中的接口和结构体的关系相对复杂，这里用一个类图可以很很好地理清楚他们之间的关系

![](/svgs/kubernetes-client-go-discovery.svg)

### ClientSet

```go
type Clientset struct {
	*discovery.DiscoveryClient
	admissionregistrationV1      *admissionregistrationv1.AdmissionregistrationV1Client
	admissionregistrationV1beta1 *admissionregistrationv1beta1.AdmissionregistrationV1beta1Client
	appsV1                       *appsv1.AppsV1Client
	appsV1beta1                  *appsv1beta1.AppsV1beta1Client
	appsV1beta2                  *appsv1beta2.AppsV1beta2Client
    ...
}
```

`Clientset` 的实现在 `k8s.io/client-go/kubernetes`中，封装了所有 `Kubernetes` 内置资源的 RESTful 操作,其中每 ResourceGroup 都是基于 `rest.Interface`的封装,Resource 和 Version 都是以函数形式暴露的,比起直接使用`RestClient`要方便的多。 由于`kubernetes`的内置资源非常多，实际上它是通过代码生成器生成的，关于代码生成器，将会在未来的文章中涉及。需要注意的是，`Clientset`不支持直接访问 CRD，如果有需求，也可以通过代码生成器重新生成`Clientset`。

### DynamicClient

> `dynamic/simple.go`

```
type dynamicClient struct {
	client *rest.RESTClient
}
```

`dynamicClient`的功能和`Clientset`类似,它直接使用了`rest.RestClient`,与`Clientset`不同的是,`dynamicClient`使用的是非结构化的数据，所有的返回结构都是 `*unstructured.Unstructured`，在其内部实现了序列化和反序列化的操作， 所以他直接能支持 CRD。

## 总结

`RestClient` 是最基础的客户端，它是 `Clientset`,`DynamicClient`,`DiscoveryClient` 的基础。Clientset 和 DynamicClient 两个客户端的作用类似，DiscoveryClient 则提供了发现 `kube-apiserv`GVR 的功能。用一个类图可以很好的体现他们之间的关系(图片比较大,可以右键新窗口打开):

![](/svgs/kubernetes-client-go-client-all.svg)

## 参考

[《Kubernetes 源码剖析》](https://weread.qq.com/web/reader/f1e3207071eeeefaf1e138akc81322c012c81e728d9d180)
