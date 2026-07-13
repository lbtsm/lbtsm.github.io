---
title: "DeFi 基础 - Uniswap"
date: 2026-07-12
draft: false
tags: ["DeFi", "区块链", "Uniswap"]
categories: ["区块链"]
summary: "Uniswap 的核心特性"
image: cover.png
---

## Summary
目前Uniswap是Defi现货交易的一个重要基础，只要你想**接触区块链就会碰到它**，并且它的设计范式是被整个行业复制和抄袭，从2018年开始，截止到目前为止一共更新了四个版本，每个版本都有自己的特性，接下来我们逐一讲解

## CLMM

之前在 Solana 上的 DEX 聚合器 - Jupiter 中提到了 AMM 这个概念,这个是属于 Uniswap v2 中提到的,它有一个缺陷就是无常损失,意思是你一直持有投入到 LP 的 token,比你把 token 投入到 LP 中获取的利益更多。为了弥补这个缺陷(当然还有其他的问题),Uniswap v3 引入了 CLMM(集中流动性做市)。
