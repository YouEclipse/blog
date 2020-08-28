---
title: "Isito 1.7 holdApplicationUntilProxyStarts是如何保证sidecar的启动顺序的"
date: 2020-08-27T23:43:20+08:00
tags: ["istio"]
categories: ["istio"]
draft: true
---

2020 年 8 月 27 日,Istio 发布了 1.7 版本，宣称这是一个真正产线可用的版本.其中针对`Traffic Management`增了一个配置`values.global.proxy.holdApplicationUntilProxyStarts`,可以使得其他容器在`sidecar` ready 之后起来，这解决了一个 kubernetes 1.18 之前没有 sidecar container 的一大痛点：sidecar 和应用容器的启动顺序是不确定的，如果应用容器先启动了，sidecar 还未完成启动，这时候用户容器往外发送请求，请求仍然会被拦截，发往未启动的 envoy，就会导致请求失败。我们在现实中的场景就是服务启动时要拉去配置中心的配置，但是由于 sidecar 未启动，拉去配置失败，服务则会 panic,导致容器只能等待 sidecar 起来后被 kubernetes 自动拉起.为了解决这个问题，我们参考业界普遍的作法之一，在服务的基础库中加了对 envoy 的健康检查，检查到 envoy 启动了再去请求配置中心，这样就避免了因为 envoy 未启动带了的服务异常关闭的问题.

```go

```
