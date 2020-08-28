---
title: "Isito 1.7 是如何保证sidecar的启动顺序的"
date: 2020-08-27T23:43:20+08:00
tags: ["istio", "go"]
categories: ["istio", "go"]
draft: true
---

## 前言

2020 年 8 月 27 日,Istio 发布了 1.7 版本，宣称这是一个真正产线可用的版本.其中针对`Traffic Management`增了一个配置`values.global.proxy.holdApplicationUntilProxyStarts`,可以支持让 sidecar 启动后才启动你的应用容器，这解决了一个 Istio 一直存在的的一大痛点：

<!--more-->

sidecar 容器 和应用容器的启动顺序是不确定的，如果应用容器先启动了，sidecar 还未完成启动，这时候用户容器往外发送请求，请求仍然会被拦截，发往未启动的 envoy，就会导致请求失败。

## 现状

我在公司落地`Istio`时就遇到这个问题, 我们使用的是 1.6 版本,具体的场景就是微服务启动初始化时要调接口拉取配置中心的配置，但是由于 sidecar 未启动，拉取配置失败，服务则会终止启动,导致容器只能等待 sidecar 起来后被 `Kubernetes` 的`restartPolicy` 机制自动拉起.为了解决这个问题，目前业界有比较普遍的作法，一种是应用容器延迟几秒启动;另一种则是在应用容器的启动脚本调用 envoy 健康检查接口，确保 envoy 启动了再启动应用，这样就避免了应用启动时的访问异常.

由于我们公司目前的微服务基本都是 Go 编写的,而服务初始化拉取配置的逻辑都使用了基础库中封装的逻辑,为了方便,我们直接在基础库拉取配置的代码之前加了这么一段逻辑,就是每隔一秒调用`envoy`的健康检查接口`/healthz/ready`,直到返回 200 或者超时(理论上此时 envoy 已经启动),则继续后续的服务初始化逻辑.

```go
...
tic := time.NewTicker(1 * time.Second)
after := time.After(1 * time.Minute)
SIDECAR_CHECK:
for {
    select {
        //每秒检查一次envoy是否启动
    case <-tic.C:
        logger.Infof("[main] sidecar health checking")
        if sidecarHealthCheck() {
            break SIDECAR_CHECK
        }
        //超过1分钟默认envoy已经启动
    case <-after:
        logger.Warn("[main] sidecar health check timeout after 1 minutes")
        break SIDECAR_CHECK
    }
}

...

func sidecarHealthCheck() bool {
	cli := http.Client{
		Timeout: 1 * time.Second,
	}

	resp, err := cli.Get("http://127.0.0.1:15021/healthz/ready")
	if err != nil {
		logger.Warn("[main] sidecarHealthCheck failed,err", err)
		return false
	}
	if resp.StatusCode == 200 {
		return true
	}
	return false
}

```

加上这段逻辑,基本上解决了我们服务部署时启动异常的问题.这么做,虽然达到了目的,但是所有的服务都需要重新打包部署,实在是不够优雅,但是有没有更好的实现方式呢?

## Istio 1.7 的实现

实际上,为了解决 sidecar 启动顺序的问题,`Kubernetes`1.18 之后特别引入了`sidecar container`的概念,也就是说,

在看过`kubelet`源码之前,我们都会下意识的认为出现这个问题提的原因是因为同一个 pod 中的容器都是同时开始启动的,应用容器启动的时间比 sidecar 容器启动时间短导致的.实际上,这个不是导致问题出现的绝对原因,看了`kubelet`的源码,你会发现容器实际上是按顺序启动的:

> [`kubelet/kuberuntime/kuberuntime_manager.go`](https://github.com/kubernetes/kubernetes/blob/v1.18.6/pkg/kubelet/kuberuntime/kuberuntime_manager.go#L830-L833)

```go
    // Step 7: start containers in podContainerChanges.ContainersToStart.
	for _, idx := range podContainerChanges.ContainersToStart {
		start("container", containerStartSpec(&pod.Spec.Containers[idx]))
	}
```

假设我们的容器的镜像都已经在本地了,那么启动应用容器花的时间几乎可以忽略不计了,也就是说,容器的启动时间点几乎是同时的.在这种情况下,调整容器的顺序并没有多大意义.

## 参考

[PR#24737](https://github.com/istio/istio/pull/24737/files#)

[Delaying application start until sidecar is ready](https://medium.com/@marko.luksa/delaying-application-start-until-sidecar-is-ready-2ec2d21a7b74)

[Istio-handbook](https://www.servicemesher.com/istio-handbook/practice/faq.html)

[Container Lifecycle Hooks](https://kubernetes.io/zh/docs/concepts/containers/container-lifecycle-hooks/)
