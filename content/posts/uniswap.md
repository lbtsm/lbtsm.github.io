---
title: "DeFi 基础 - Uniswap"
date: 2026-07-12
draft: false
tags: ["DeFi", "区块链", "Uniswap"]
categories: ["区块链"]
summary: "Uniswap 的核心特性与 CLMM 集中流动性做市模型笔记。"
---

## 特性

## CLMM

之前在 Solana 上的 DEX 聚合器 - Jupiter 中提到了 AMM 这个概念,这个是属于 Uniswap v2 中提到的,它有一个缺陷就是无常损失,意思是你一直持有投入到 LP 的 token,比你把 token 投入到 LP 中获取的利益更多。为了弥补这个缺陷(当然还有其他的问题),Uniswap v3 引入了 CLMM(集中流动性做市)。
