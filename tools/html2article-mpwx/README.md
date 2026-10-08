# 公众号发布

```sh
# 参考来源：https://github.com/ytygxfmgzx/html2article-mpwx.git
# Edge中加载步骤：html2article-mpwx.zip解压 --> 打开Edge --> edge://extensions/ --> 开发者模式打开 --> 加载解压缩的扩展
# 登录https://mp.weixin.qq.com/ --> 点击插件html2article --> 粘贴html --> 注入到正文

# 1. 支持WeChat公众号html语法
# 2. 支持Mathjax数学公式渲染
```

## 技术栈图标

```sh
# 创建独立虚拟环境（推荐，避免依赖冲突）
python3 -m venv .venv
source .venv/bin/activate

# 无第三方依赖，直接用标准库运行
python generate_tech_stack.py --list
ICONS="vuejs,react,python,ActivityPub,Actix,Adonis,AfterEffects,AiScript,AlpineJS,Anaconda,AndroidStudio,Angular,Ansible,Apollo,Apple,Appwrite,Arch,Arduino,Astro,Atom"
python generate_tech_stack.py --icons "$ICONS" --theme dark -o out.svg
```
