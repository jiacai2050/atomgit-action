# Atomgit Action

一个用于将 GitHub release 产物同步到 [atomgit](https://atomgit.com) 的 GitHub Action。

## 用法

```yaml
- name: Sync release to atomgit
  uses: jiacai2050/atomgit-action@v1
  with:
    tag: ${{ github.ref_name }}
    owner: ${{ github.repository_owner }}
    repo: ${{ github.event.repository.name }}
    atomgit_token: ${{ secrets.ATOMGIT_TOKEN }}
```

## 参数

| 参数 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `tag` | 是 | | Release tag，如 `v1.2.0` |
| `owner` | 是 | | 仓库所属者（用于 API 路径） |
| `repo` | 是 | | 仓库名称 |
| `atomgit_token` | 是 | | atomgit API token |
| `atomgit_user` | 否 | 与 `owner` 相同 | git push 用的用户名。仓库属于组织时需要单独指定 |
| `upload_jobs` | 否 | `4` | 并发上传数 |

## 执行流程

1. 通过 git 推送 tag 到 atomgit
2. 创建或更新 release，同步 GitHub 的 release 描述
3. 从 GitHub 下载 release 附件
4. 并发上传附件到 atomgit（自动跳过源码归档）

## 完整示例（配合 GoReleaser）

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  goreleaser:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
      - uses: goreleaser/goreleaser-action@v6
        with:
          args: release --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  atomgit:
    needs: goreleaser
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: jiacai2050/atomgit-action@v1
        with:
          tag: ${{ github.ref_name }}
          owner: ${{ github.repository_owner }}
          repo: ${{ github.event.repository.name }}
          atomgit_token: ${{ secrets.ATOMGIT_TOKEN }}
```

## 手动同步

通过 workflow_dispatch 手动同步指定 tag：

```yaml
name: Sync to atomgit

on:
  workflow_dispatch:
    inputs:
      tag:
        description: 'Release tag'
        required: true

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: jiacai2050/atomgit-action@v1
        with:
          tag: ${{ inputs.tag }}
          owner: ${{ github.repository_owner }}
          repo: ${{ github.event.repository.name }}
          atomgit_token: ${{ secrets.ATOMGIT_TOKEN }}
```

## License

MIT
