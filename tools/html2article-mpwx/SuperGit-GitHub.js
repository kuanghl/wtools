// ==UserScript==
// @name         SuperGit - Github国内加速助手
// @namespace    https://hsya.top/
// @version      1.11.0
// @description  专为国内开发者打造。自动在 GitHub 页面注入「镜像下载」按钮，覆盖 Release、Raw、Clone ZIP 等 8 大场景，一键选择最优镜像节点，下载速度提升数十倍。
// @author       划水鸭
// @license      MIT
// @homepage     https://hsya.top/supergit.html
// @supportURL   https://hsya.top/supergit.html
// @match        *://github.com/*
// @match        *://gist.github.com/*
// @match        *://*.github.com/*
// @connect      github.com
// @connect      githubusercontent.com
// @connect      codeload.github.com
// @connect      raw.githubusercontent.com
// @connect      api.akams.cn
// @connect      hsya.top
// @connect      *
// @icon         https://hsya.top/static/img/supergit.png
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_xmlhttpRequest
// @grant        GM_download
// @grant        GM_openInTab
// @grant        GM_addStyle
// @grant        GM_info
// @grant        GM_registerMenuCommand
// @run-at       document-idle
// ==/UserScript==

(function() {
	'use strict';
	if (window.__supergit_injected) return;
	window.__supergit_injected = true;

	const VERSION = 'v' + GM_info.script.version;

	// 图标：GitHub CSP 限制外域 img-src，需通过 GM_xmlhttpRequest 预加载转 base64
	const ICON_URL = 'https://hsya.top/static/img/supergit.png';
	let ICON_URI = 'data:image/svg+xml,' + encodeURIComponent(
		'<svg t="1780135787014" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="6448" width="200" height="200"><path d="M636.992 571.104c13.728 0 25.28 6.72 35.264 20.352 9.92 13.504 14.976 30.208 14.976 49.92 0 19.808-4.992 36.512-14.976 50.016s-21.696 20.288-35.264 20.288c-14.432 0-26.848-6.72-36.832-20.288-9.824-13.504-14.88-30.208-14.88-50.016s4.896-36.448 14.88-49.92c9.984-13.664 22.464-20.352 36.832-20.352z m176.608-182.88c38.464 41.696 57.888 92.288 57.888 151.616 0 38.496-4.544 73.152-13.28 103.968-8.896 30.656-20.128 55.776-33.536 74.976a214.56 214.56 0 0 1-50.08 50.72c-19.904 14.752-38.24 25.28-54.784 32.064s-35.584 12.032-57.12 15.68c-21.28 3.744-37.376 5.76-48.544 6.336-10.752 0.48-22.464 0.704-35.104 0.704-2.816 0-12.32 0.32-28.128 0.768-15.424 0.64-28.672 0.928-38.976 0.928s-23.552-0.32-38.976-0.928a1798.08 1798.08 0 0 0-28.128-0.768c-12.64 0-24.448-0.16-35.136-0.704-11.2-0.544-27.264-2.56-48.448-6.336a256.736 256.736 0 0 1-57.184-15.68c-16.544-6.72-34.848-17.312-54.656-32.064a218.624 218.624 0 0 1-50.176-50.72c-13.408-19.2-24.704-44.32-33.536-74.976-8.704-30.816-13.248-65.472-13.248-103.968 0-59.328 19.36-109.92 57.92-151.616-4.256-2.08-4.48-22.848-0.672-62.464 3.424-39.648 11.84-76.16 25.504-109.472 48.096 5.12 107.264 32.256 178.144 81.248 23.936-6.24 56.704-9.44 98.496-9.44 43.84 0 76.608 3.2 98.528 9.44 32.288-21.792 63.2-39.648 92.672-53.216 29.952-13.408 51.488-21.344 65.056-23.392l20.288-4.64c13.728 33.312 22.144 69.92 25.6 109.472 3.968 39.584 3.744 60.384-0.48 62.464z m-299.936 401.632c86.496 0 151.712-10.368 196-31.136 44.16-20.832 66.624-63.68 66.624-128.256 0-37.44-14.112-68.8-42.304-93.824a95.712 95.712 0 0 0-51.04-24.992c-19.04-3.136-48.448-3.136-88.16 0-39.552 3.2-66.624 4.64-81.184 4.64-19.808 0-41.312-1.056-68-3.136a2103.584 2103.584 0 0 0-62.528-3.904 192.672 192.672 0 0 0-49.216 5.504c-17.824 4.256-32.256 11.424-43.936 21.792-26.88 24-40.512 55.2-40.512 93.824 0 64.608 21.888 107.424 65.6 128.192 43.68 20.896 108.704 31.2 195.232 31.2z m-125.088-218.752c13.568 0 25.248 6.72 35.136 20.352 9.92 13.504 14.944 30.208 14.944 49.92 0 19.808-4.96 36.512-14.944 50.016-9.888 13.504-21.664 20.288-35.136 20.288-14.56 0-26.912-6.72-36.896-20.288-9.888-13.504-14.944-30.208-14.944-50.016s4.96-36.448 14.944-49.92c9.984-13.664 22.368-20.352 36.896-20.352z" fill="#ffffff" p-id="6449"></path></svg>'
	);

	function preloadIcon() {
		return new Promise((resolve) => {
			GM_xmlhttpRequest({
				method: 'GET',
				url: ICON_URL,
				responseType: 'blob',
				timeout: 10000,
				onload: (resp) => {
					try {
						const reader = new FileReader();
						reader.onloadend = () => {
							if (reader.result) ICON_URI = reader.result;
							resolve();
						};
						reader.onerror = () => resolve();
						reader.readAsDataURL(resp.response);
					} catch {
						resolve();
					}
				},
				onerror: () => resolve(),
				ontimeout: () => resolve(),
			});
		});
	}

	// 下载小图标
	const DL_SVG = '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>';

	// GitHub 常见可下载位置配置
	const INJECT_SCENARIOS = {
		'release-zip': {
			label: 'Release ZIP/Tar',
			desc: 'Release 页面的源码压缩包',
			defaultOn: true
		},
		'release-asset': {
			label: 'Release 附件',
			desc: 'Release 页面的上传附件',
			defaultOn: true
		},
		'raw-file': {
			label: 'Raw 原始文件',
			desc: '代码文件查看页的原始文件',
			defaultOn: true
		},
		'clone-zip': {
			label: 'Clone 弹框 ZIP',
			desc: '仓库主页 Clone 弹框的 ZIP 下载',
			defaultOn: true
		},
		'repo-archive': {
			label: '仓库 Code 按钮',
			desc: '仓库主页 Code 按钮旁',
			defaultOn: true
		},
		'lfs-file': {
			label: 'LFS 大文件',
			desc: 'Git LFS 管理的大文件',
			defaultOn: true
		},
		'gist-raw': {
			label: 'Gist 原始文件',
			desc: 'Gist 代码片段的原始文件',
			defaultOn: true
		},
		'compare-diff': {
			label: 'Compare/Diff 补丁',
			desc: '代码比较页面的 Patch/Diff',
			defaultOn: true
		},
	};

	// ===== 状态 =====
	let allNodes = [];
	let visibleKeys = [];
	let panelOpen = false;
	let injectConfig = {};

	// ===== Storage 封装 (GM API) =====
	function gmGet(keys) {
		const result = {};
		if (typeof keys === 'string') keys = [keys];
		for (const k of keys) {
			try {
				result[k] = GM_getValue(k);
			} catch {
				result[k] = undefined;
			}
		}
		return result;
	}

	function gmSet(obj) {
		for (const [k, v] of Object.entries(obj)) {
			try {
				GM_setValue(k, v);
			} catch (e) {
				console.error('[SuperGit] GM_setValue error:', e);
			}
		}
	}

	// ===== 跨域请求 (GM_xmlhttpRequest) =====
	function gmFetch(url, options = {}) {
		return new Promise((resolve, reject) => {
			GM_xmlhttpRequest({
				method: options.method || 'GET',
				url: url,
				headers: options.headers || {},
				responseType: options.responseType || '',
				timeout: options.timeout || 30000,
				onload: (resp) => {
					if (resp.status >= 200 && resp.status < 400) {
						resolve(resp);
					} else {
						reject(new Error(`HTTP ${resp.status}`));
					}
				},
				onerror: (err) => reject(err),
				ontimeout: () => reject(new Error('Timeout')),
			});
		});
	}

	// ===== 从 API 加载镜像节点 =====
	async function fetchMirrorNodesFromAPI() {
		const resp = await gmFetch('https://api.akams.cn/github');
		if (resp.status >= 200 && resp.status < 400) {
			const data = typeof resp.response === 'string' ? JSON.parse(resp.response) : resp.response;
			if (data.code === 200 && data.data && Array.isArray(data.data)) {
				const filtered = data.data
					.filter(node => node.latency > 0 && node.latency < 1500)
					.sort((a, b) => a.latency - b.latency);
				if (!filtered.length) throw new Error('API返回节点列表为空');
				return filtered;
			}
			throw new Error('API返回数据格式错误');
		}
		throw new Error(`HTTP错误`);
	}

	// ===== 从远程 JS 兜底加载镜像节点 =====
	async function fetchMirrorNodesFromFallback() {
		console.log('[SuperGit] 正在从远程脚本加载镜像节点...');
		const resp = await gmFetch('https://hsya.top/static/js/super-git.js');
		if (resp.status !== 200) throw new Error(`远程脚本HTTP错误: ${resp.status}`);
		const text = typeof resp.response === 'string' ? resp.response : JSON.stringify(resp.response);

		// 提取 DEFAULT_NODES 数组
		const match = text.match(/const\s+DEFAULT_NODES\s*=\s*\[([\s\S]*?)\]/);
		if (!match) throw new Error('无法从远程脚本提取节点列表');

		// 解析所有 URL
		const urlRegex = /"([^"]+)"/g;
		const nodes = [];
		let urlMatch;
		while ((urlMatch = urlRegex.exec(match[1])) !== null) {
			nodes.push(urlMatch[1]);
		}

		if (!nodes.length) throw new Error('远程脚本中未找到节点URL');

		// 对节点进行测速
		console.log(`[SuperGit] 找到 ${nodes.length} 个备用节点，开始测速...`);
		const results = await testNodesWithFallback(nodes);
		const valid = results
			.filter(r => r.success)
			.map(r => ({ url: r.url, latency: r.latencyMs }))
			.sort((a, b) => a.latency - b.latency);

		if (!valid.length) throw new Error('备用节点测速全部失败');
		console.log(`[SuperGit] 备用节点测速完成: ${valid.length} 个可用`);
		return valid;
	}

	// ===== 使用 GM_xmlhttpRequest 对备用节点列表测速 =====
	function testNodesWithFallback(urls) {
		return new Promise((resolve) => {
			const results = [];
			const queue = [...urls];
			const timeout = 1500;
			const concurrency = 8;
			let active = 0;
			let finished = false;

			// 超时保护：60秒后强制结束
			const safetyTimer = setTimeout(() => {
				if (!finished) {
					finished = true;
					results.sort((a, b) => {
						if (a.success !== b.success) return a.success ? -1 : 1;
						return a.latencyMs - b.latencyMs;
					});
					resolve(results);
				}
			}, 60000);

			function next() {
				while (active < concurrency && queue.length) {
					const url = queue.shift();
					active++;
					const start = Date.now();
					const testUrl = url + (url.includes('?') ? '&' : '?') + '_=' + Date.now() + Math.random();
					GM_xmlhttpRequest({
						method: 'GET',
						url: testUrl,
						timeout: timeout,
						onload: () => {
							results.push({ url, success: true, latencyMs: Date.now() - start });
							active--;
							next();
						},
						onerror: () => {
							results.push({ url, success: false, latencyMs: timeout, errorMsg: '连接失败' });
							active--;
							next();
						},
						ontimeout: () => {
							results.push({ url, success: false, latencyMs: timeout, errorMsg: '超时' });
							active--;
							next();
						}
					});
				}
				if (queue.length === 0 && active === 0) {
					if (!finished) {
						finished = true;
						clearTimeout(safetyTimer);
						results.sort((a, b) => {
							if (a.success !== b.success) return a.success ? -1 : 1;
							return a.latencyMs - b.latencyMs;
						});
						resolve(results);
					}
				}
			}
			next();
		});
	}

	// ===== 硬编码最后兜底节点（API + 远程脚本均不可用时） =====
	const LAST_RESORT_NODES = [
		"https://gh-proxy.com/",
		"https://ghproxy.net/",
		"https://hub.ddayh.com/",
		"https://fastgit.cc/",
		"https://ghproxy.053000.xyz/",
		"https://gh.con.sh/"
	];

	// ===== 加载镜像节点 (原 background.js loadMirrorNodes) =====
	async function loadMirrorNodes(source) {
		source = source || '自动';
		const oldNodes = allNodes.slice();
		try {
			console.log(`[${source}刷新] 正在从 API 加载镜像节点...`);
			allNodes = await fetchMirrorNodesFromAPI();
			console.log(`[${source}刷新] 加载了 ${allNodes.length} 个镜像节点 (API)`);
			// 成功才更新缓存和时间戳
			gmSet({
				mirrorNodes: allNodes,
				sg_nodes_update_time: Date.now()
			});
		} catch (error) {
			console.warn(`[${source}刷新] API 加载失败:`, error.message);
			try {
				allNodes = await fetchMirrorNodesFromFallback();
				console.log(`[${source}刷新] 从兜底脚本加载了 ${allNodes.length} 个镜像节点`);
				gmSet({
					mirrorNodes: allNodes,
					sg_nodes_update_time: Date.now()
				});
			} catch (fallbackError) {
				console.error(`[${source}刷新] 兜底加载也失败:`, fallbackError);
				// 全部外部资源失败，使用硬编码节点做最后测速
				try {
					console.log(`[${source}刷新] 使用硬编码兜底节点...`);
					const results = await testNodesWithFallback(LAST_RESORT_NODES);
					const valid = results
						.filter(r => r.success)
						.map(r => ({ url: r.url, latency: r.latencyMs }))
						.sort((a, b) => a.latency - b.latency);
					if (valid.length) {
						allNodes = valid;
					} else {
						// 所有方式均失败，保留旧节点
						allNodes = oldNodes;
					}
				} catch {
					allNodes = oldNodes;
				}
				// 不更新缓存，让下次启动时重新尝试
			}
		}
	}

	// ===== 初始化 =====
	async function init() {
		try {
			// 预加载图标（绕过 GitHub CSP）— 后台执行不阻塞
			const iconPromise = preloadIcon();

			// 优先从 GM storage 加载缓存
			const store = gmGet(['mirrorNodes', 'sg_visible_keys', 'sg_inject_config', 'sg_nodes_update_time']);

			if (store.mirrorNodes && Array.isArray(store.mirrorNodes) && store.mirrorNodes.length > 0) {
				allNodes = store.mirrorNodes;
				console.log('[SuperGit] 从本地存储加载镜像节点:', allNodes.length);
			}

			visibleKeys = store.sg_visible_keys || [];
			if (!visibleKeys.length && allNodes.length) {
				visibleKeys = allNodes.slice(0, 10).map(n => nodeKey(n));
				saveVisibleKeys();
			}

			// 加载注入配置
			injectConfig = store.sg_inject_config || {};
			Object.keys(INJECT_SCENARIOS).forEach(k => {
				if (injectConfig[k] === undefined) {
					injectConfig[k] = INJECT_SCENARIOS[k].defaultOn;
				}
			});
			saveInjectConfig();

			// 立即注入 UI（不等待节点加载，也不等待图标）
			injectUI();
			bindEvents();
			refreshNodeList();
			setupInject();

			// 后台加载图标
			iconPromise.then(() => {
				// 图标加载完成后更新面板和弹窗中的图标
				document.querySelectorAll('#supergit-fab img, #supergit-panel h3 img, #sg-download-modal h4 img').forEach(img => {
					img.src = ICON_URI;
				});
			});

			// 周期刷新 (每小时)
			setInterval(loadMirrorNodes, 60 * 60 * 1000);

			// 缓存过期则刷新（异步，不阻塞 UI）
			const lastUpdate = store.sg_nodes_update_time || 0;
			const expired = Date.now() - lastUpdate > 60 * 60 * 1000;
			if (expired || !allNodes.length) {
				console.log(`[SuperGit] 缓存${expired ? '已过期' : '为空'}，正在刷新节点...`);
				loadMirrorNodes().then(() => {
					const validKeys = new Set(allNodes.map(n => nodeKey(n)));
					visibleKeys = visibleKeys.filter(k => validKeys.has(k));
					if (!visibleKeys.length && allNodes.length) visibleKeys = allNodes.slice(0, 10).map(n => nodeKey(n));
					saveVisibleKeys();
					refreshNodeList();
					if (!allNodes.length) autoRefreshNodes();
				});
			} else {
				// 缓存未过期，后台异步加载最新节点
				if (allNodes.length) {
					console.log('[SuperGit] 缓存可用，后台异步加载最新节点...');
					loadMirrorNodes().then(() => {
						const validKeys = new Set(allNodes.map(n => nodeKey(n)));
						visibleKeys = visibleKeys.filter(k => validKeys.has(k));
						if (!visibleKeys.length && allNodes.length) visibleKeys = allNodes.slice(0, 10).map(n => nodeKey(n));
						saveVisibleKeys();
						refreshNodeList();
					});
				}
			}

			// 注册油猴菜单命令
			GM_registerMenuCommand('打开节点管理面板', () => {
				if (!panelOpen) togglePanel();
			});
		} catch (err) {
			console.error('[SuperGit] 初始化出错:', err);
		}
	}

	// ===== 工具函数 =====
	function nodeKey(node) {
		return node.url || '';
	}

	function shortDomain(url) {
		try {
			const h = new URL(url).hostname.replace('www.', '');
			const parts = h.split('.');
			return parts.length > 2 ? parts.slice(-2).join('.') : h;
		} catch {
			return url;
		}
	}

	function delayClass(ms) {
		return ms < 300 ? 'sg-delay-fast' : ms < 800 ? 'sg-delay-medium' : 'sg-delay-slow';
	}

	function dmDelayClass(ms) {
		return ms < 300 ? 'sg-dm-fast' : ms < 800 ? 'sg-dm-medium' : 'sg-dm-slow';
	}

	function delayPercent(ms) {
		return Math.min(100, (ms / 1500) * 100);
	}

	function saveVisibleKeys() {
		gmSet({
			sg_visible_keys: visibleKeys
		});
	}

	function saveInjectConfig() {
		gmSet({
			sg_inject_config: injectConfig
		});
	}

	// 生成镜像链接
	function mirrorUrl(githubUrl, nodeUrl) {
		if (!nodeUrl || !githubUrl) return '';
		const base = nodeUrl.replace(/\/+$/, '');
		const path = githubUrl.replace(/^\/+/, '');
		return base + '/' + path;
	}

	// ===== 私有仓库检测 =====
	const REPO_VISIBILITY_CACHE = new Map();
	const GITHUB_RESERVED_OWNERS = new Set([
		'about', 'account', 'apps', 'codespaces', 'collections', 'contact', 'customer-stories',
		'dashboard', 'enterprise', 'events', 'explore', 'features', 'home', 'issues', 'join',
		'login', 'logout', 'marketplace', 'new', 'notifications', 'orgs', 'organizations',
		'pricing', 'projects', 'pulls', 'readme', 'search', 'security', 'settings', 'signup',
		'site', 'sponsors', 'stars', 'topics', 'trending', 'users', 'watching'
	]);

	// 从 GitHub / codeload / raw 链接中解析 owner/repo
	function parseRepoFromUrl(url) {
		if (!url) return '';
		let u;
		try {
			u = new URL(url, location.href);
		} catch {
			return '';
		}
		const host = u.hostname.toLowerCase().replace(/^www\./, '');
		const parts = u.pathname.split('/').filter(Boolean);
		if (!parts.length) return '';
		if (host === 'codeload.github.com' || host === 'raw.githubusercontent.com') {
			return parts.length >= 2 ? `${parts[0]}/${parts[1]}` : '';
		}
		if (host !== 'github.com' && !host.endsWith('.github.com')) return '';
		if (host === 'gist.github.com') return '';
		if (GITHUB_RESERVED_OWNERS.has(parts[0].toLowerCase())) return '';
		if (parts.length < 2) return '';
		return `${parts[0]}/${parts[1].replace(/\.git$/i, '')}`;
	}

	// 只对当前页面所属仓库做同步判断，避免把页面上的 Public/Private 标签错用到其他仓库
	function isPrivateRepo(githubUrl) {
		const fullName = parseRepoFromUrl(githubUrl);
		if (!fullName) return false;
		const cacheKey = fullName.toLowerCase();
		if (REPO_VISIBILITY_CACHE.has(cacheKey)) return REPO_VISIBILITY_CACHE.get(cacheKey);

		// 当前页面必须就是这个仓库（GitHub SPA 导航后 meta 可能滞后，因此以 location 为准）
		const pageRepo = parseRepoFromUrl(location.href);
		if (!pageRepo || pageRepo.toLowerCase() !== cacheKey) return false;

		let isPrivate = null;
		const pageNwo = (document.querySelector('meta[name="octolytics-dimension-repository_nwo"]')
			?.getAttribute('content') || '').trim();
		const pagePublic = document.querySelector('meta[name="octolytics-dimension-repository_public"]')
			?.getAttribute('content');
		if (pageNwo && pageNwo.toLowerCase() === cacheKey) {
			if (pagePublic === 'false') {
				isPrivate = true;
			} else if (pagePublic === 'true') {
				isPrivate = false;
			}
		}

		if (isPrivate === null) {
			const label = (document.querySelector('[data-testid="repo-visibility-label"]')
				?.textContent || '').trim().toLowerCase();
			if (label) isPrivate = label.includes('private') || label.includes('私有');
		}

		if (isPrivate === null) {
			const oldLabel = (document.querySelector('#repo-title-component .Label, #repo-title-component [class*="Label"]')
				?.textContent || '').trim().toLowerCase();
			if (oldLabel) isPrivate = oldLabel.includes('private') || oldLabel.includes('私有');
		}

		if (isPrivate !== null) REPO_VISIBILITY_CACHE.set(cacheKey, isPrivate);
		return isPrivate === true;
	}

	// 兜底：节点为空时自动刷新一次
	let _autoRefreshing = false;

	function autoRefreshNodes(onDone) {
		if (_autoRefreshing || allNodes.length > 0) {
			onDone?.();
			return;
		}
		_autoRefreshing = true;
		console.log('[SuperGit] 节点列表为空，自动刷新...');
		loadMirrorNodes().then(() => {
			_autoRefreshing = false;
			if (allNodes.length) {
				visibleKeys = visibleKeys.filter(k => allNodes.some(n => nodeKey(n) === k));
				if (!visibleKeys.length) visibleKeys = allNodes.slice(0, 10).map(n => nodeKey(n));
				saveVisibleKeys();
				refreshNodeList();
				showToast(`自动刷新成功，${allNodes.length} 个节点`);
			} else {
				showToast('自动刷新失败，请手动刷新');
			}
			onDone?.();
		}).catch(() => {
			_autoRefreshing = false;
			showToast('自动刷新失败，请手动刷新');
			onDone?.();
		});
	}

	function showToast(msg) {
		const t = document.createElement('div');
		t.className = 'sg-toast';
		t.textContent = msg;
		document.body.appendChild(t);
		requestAnimationFrame(() => t.classList.add('sg-show'));
		setTimeout(() => {
			t.classList.remove('sg-show');
			setTimeout(() => t.remove(), 300);
		}, 2000);
	}

	// 私有仓库提示弹窗（阻止镜像下载）
	function showPrivateRepoNotice() {
		let modal = document.getElementById('sg-private-notice');
		if (modal) {
			modal.classList.add('sg-visible');
			return;
		}

		modal = document.createElement('div');
		modal.id = 'sg-private-notice';
		modal.innerHTML = `
            <div class="sg-private-overlay"></div>
            <div class="sg-private-card" role="dialog" aria-modal="true" aria-labelledby="sg-private-title">
                <div class="sg-private-icon">!</div>
                <h4 id="sg-private-title">私有仓库，不支持镜像下载</h4>
                <p>第三方镜像无法访问私有仓库，请使用 GitHub 原生下载（Download ZIP / Release 附件）或 <code>git clone</code>。</p>
                <button type="button" class="sg-private-ok">知道了</button>
            </div>`;
		document.body.appendChild(modal);

		const close = () => {
			if (!modal) return;
			modal.classList.remove('sg-visible');
			document.removeEventListener('keydown', onKey);
			setTimeout(() => modal.remove(), 200);
		};
		const onKey = (e) => {
			if (e.key === 'Escape') close();
		};
		modal.querySelector('.sg-private-overlay').addEventListener('click', close);
		modal.querySelector('.sg-private-ok').addEventListener('click', close);
		document.addEventListener('keydown', onKey);
		requestAnimationFrame(() => modal.classList.add('sg-visible'));
	}

	// ===== 注入 CSS =====
	GM_addStyle(`
/* SuperGit 右下角浮动按钮 */
#supergit-fab {
    position: fixed;
    bottom: 24px;
    right: 24px;
    z-index: 2147483647;
    width: 48px;
    height: 48px;
    border-radius: 50%;
    border: none;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #2da44e;
    color: #fff;
    font-size: 22px;
    box-shadow: 0 4px 14px rgba(0, 0, 0, 0.3);
    transition: all 0.2s ease;
    line-height: 1;
}
#supergit-fab:hover {
    transform: scale(1.1);
    box-shadow: 0 6px 20px rgba(0, 0, 0, 0.4);
}
#supergit-fab:active {
    transform: scale(0.95);
}
#supergit-fab svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

/* 脉冲动画 - 有节点时绿色脉冲 */
@keyframes sg-pulse {
    0%   { box-shadow: 0 0 0 0 rgba(45, 164, 78, 0.5); }
    70%  { box-shadow: 0 0 0 10px rgba(45, 164, 78, 0); }
    100% { box-shadow: 0 0 0 0 rgba(45, 164, 78, 0); }
}
#supergit-fab.sg-pulse {
    animation: sg-pulse 2s infinite;
}

/* 面板遮罩 */
#supergit-overlay {
    position: fixed;
    inset: 0;
    z-index: 2147483646;
    background: rgba(0, 0, 0, 0.5);
    opacity: 0;
    transition: opacity 0.2s ease;
    pointer-events: none;
}
#supergit-overlay.sg-visible {
    opacity: 1;
    pointer-events: auto;
}

/* 管理面板 */
#supergit-panel {
    position: fixed;
    bottom: 84px;
    right: 24px;
    z-index: 2147483647;
    width: 380px;
    max-height: 520px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 12px;
    box-shadow: 0 12px 40px rgba(0, 0, 0, 0.5);
    color: #e6edf3;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    font-size: 14px;
    overflow: hidden;
    transform: translateY(20px) scale(0.95);
    opacity: 0;
    transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
    pointer-events: none;
    display: flex;
    flex-direction: column;
}
#supergit-panel.sg-visible {
    transform: translateY(0) scale(1);
    opacity: 1;
    pointer-events: auto;
}

/* 面板头部 */
.sg-panel-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 16px 20px 12px;
    border-bottom: 1px solid #21262d;
    flex-shrink: 0;
}
.sg-panel-header h3 {
    margin: 0;
    font-size: 15px;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 8px;
    color: #e6edf3;
}
.sg-panel-header h3 svg {
    width: 20px;
    height: 20px;
    fill: #2da44e;
}
.sg-close-btn {
    width: 32px;
    height: 32px;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: #8b949e;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s;
}
.sg-close-btn:hover {
    background: #21262d;
    color: #e6edf3;
}

/* 状态栏 */
.sg-status-bar {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 20px;
    font-size: 12px;
    color: #8b949e;
    border-bottom: 1px solid #21262d;
}
.sg-status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
}
.sg-status-dot.sg-online { background: #2da44e; }
.sg-status-dot.sg-offline { background: #6e7681; }
.sg-status-bar .sg-last-update {
    margin-left: auto;
}

/* 工具栏 */
.sg-toolbar {
    display: flex;
    gap: 8px;
    padding: 12px 20px;
    border-bottom: 1px solid #21262d;
}
.sg-toolbar-btn {
    padding: 6px 12px;
    border: 1px solid #30363d;
    border-radius: 6px;
    background: #21262d;
    color: #e6edf3;
    font-size: 12px;
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 4px;
    transition: all 0.15s;
    white-space: nowrap;
}
.sg-toolbar-btn:hover {
    background: #30363d;
    border-color: #8b949e;
}
.sg-toolbar-btn svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}
.sg-toolbar-btn.sg-loading {
    opacity: 0.6;
    pointer-events: none;
}
.sg-toolbar-btn svg.sg-spin {
    animation: sg-spin 1s linear infinite;
}
@keyframes sg-spin {
    to { transform: rotate(360deg); }
}

/* 节点列表 */
.sg-node-list {
    max-height: 280px;
    overflow-y: auto;
    padding: 8px 0;
    flex: 1;
}
.sg-node-list::-webkit-scrollbar {
    width: 6px;
}
.sg-node-list::-webkit-scrollbar-thumb {
    background: #30363d;
    border-radius: 3px;
}
.sg-node-item {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 20px;
    transition: background 0.15s;
}
.sg-node-item:hover {
    background: #161b22;
}

/* 自定义 Checkbox */
.sg-checkbox {
    position: relative;
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    cursor: pointer;
}
.sg-checkbox input {
    position: absolute;
    opacity: 0;
    width: 100%;
    height: 100%;
    cursor: pointer;
    margin: 0;
}
.sg-checkbox .sg-checkmark {
    width: 16px;
    height: 16px;
    border: 1.5px solid #30363d;
    border-radius: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s;
    background: #0d1117;
}
.sg-checkbox input:checked + .sg-checkmark {
    background: #2da44e;
    border-color: #2da44e;
}
.sg-checkbox input:checked + .sg-checkmark::after {
    content: '';
    width: 4px;
    height: 8px;
    border: solid #fff;
    border-width: 0 2px 2px 0;
    transform: rotate(45deg) translate(-0.5px, -0.5px);
}

.sg-node-info {
    flex: 1;
    min-width: 0;
}
.sg-node-domain {
    font-size: 13px;
    font-weight: 500;
    color: #e6edf3;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}
.sg-node-delay {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 2px;
}
.sg-delay-bar {
    height: 3px;
    border-radius: 2px;
    background: #21262d;
    flex: 1;
    max-width: 60px;
    overflow: hidden;
}
.sg-delay-bar-fill {
    height: 100%;
    border-radius: 2px;
    transition: width 0.3s ease;
}
.sg-delay-text {
    font-size: 11px;
    color: #8b949e;
}

/* 延迟颜色等级 */
.sg-delay-fast { color: #2da44e; }
.sg-delay-fast .sg-delay-bar-fill { background: #2da44e; }
.sg-delay-medium { color: #d29922; }
.sg-delay-medium .sg-delay-bar-fill { background: #d29922; }
.sg-delay-slow { color: #f85149; }
.sg-delay-slow .sg-delay-bar-fill { background: #f85149; }

.sg-node-actions {
    flex-shrink: 0;
}
.sg-test-btn {
    padding: 4px 8px;
    border: 1px solid #30363d;
    border-radius: 4px;
    background: transparent;
    color: #8b949e;
    font-size: 11px;
    cursor: pointer;
    transition: all 0.15s;
}
.sg-test-btn:hover {
    background: #21262d;
    color: #e6edf3;
    border-color: #8b949e;
}

/* 空状态 */
.sg-empty {
    padding: 32px 20px;
    text-align: center;
    color: #8b949e;
    font-size: 13px;
}

/* 提示消息 */
.sg-toast {
    position: fixed;
    bottom: 24px;
    left: 50%;
    transform: translateX(-50%) translateY(20px);
    z-index: 2147483648;
    background: #1f6feb;
    color: #fff;
    padding: 8px 20px;
    border-radius: 6px;
    font-size: 13px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
    opacity: 0;
    transition: all 0.25s ease;
    pointer-events: none;
    white-space: nowrap;
}
.sg-toast.sg-show {
    transform: translateX(-50%) translateY(0);
    opacity: 1;
}

/* ===== 私有仓库提示弹窗 ===== */
#sg-private-notice {
    position: fixed;
    inset: 0;
    z-index: 2147483649;
    display: flex;
    align-items: center;
    justify-content: center;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.2s ease;
}
#sg-private-notice.sg-visible {
    opacity: 1;
    pointer-events: auto;
}
.sg-private-overlay {
    position: absolute;
    inset: 0;
    background: rgba(0, 0, 0, 0.6);
}
.sg-private-card {
    position: relative;
    width: 380px;
    max-width: calc(100vw - 32px);
    padding: 20px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 12px;
    box-shadow: 0 16px 48px rgba(0, 0, 0, 0.5);
    color: #c9d1d9;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    transform: translateY(10px) scale(0.97);
    transition: transform 0.2s ease;
}
#sg-private-notice.sg-visible .sg-private-card {
    transform: translateY(0) scale(1);
}
.sg-private-icon {
    width: 32px;
    height: 32px;
    margin-bottom: 12px;
    border-radius: 50%;
    background: #da3633;
    color: #fff;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 18px;
    font-weight: 700;
}
.sg-private-card h4 {
    margin: 0 0 8px;
    font-size: 16px;
    color: #f0f6fc;
}
.sg-private-card p {
    margin: 0 0 16px;
    font-size: 13px;
    line-height: 1.6;
    color: #8b949e;
}
.sg-private-card code {
    padding: 1px 5px;
    border-radius: 4px;
    background: #21262d;
    font-size: 12px;
}
.sg-private-ok {
    padding: 6px 16px;
    border: none;
    border-radius: 6px;
    background: #238636;
    color: #fff;
    font-size: 13px;
    cursor: pointer;
}
.sg-private-ok:hover {
    background: #2ea043;
}

/* ===== 下载进度卡片 ===== */
#sg-download-progress {
    position: fixed;
    right: 24px;
    bottom: 84px;
    z-index: 2147483647;
    display: flex;
    flex-direction: column;
    gap: 8px;
    width: 340px;
    max-width: calc(100vw - 32px);
    max-height: 60vh;
    overflow-y: auto;
    pointer-events: none;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
}
#sg-download-progress > * {
    pointer-events: auto;
}
.sg-dlp-card {
    padding: 10px 12px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 10px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    color: #c9d1d9;
    font-size: 12px;
    animation: sg-dlp-in 0.2s ease;
}
@keyframes sg-dlp-in {
    from { opacity: 0; transform: translateY(8px); }
    to { opacity: 1; transform: translateY(0); }
}
.sg-dlp-card.sg-dlp-leaving {
    opacity: 0;
    transform: translateY(8px);
    transition: opacity 0.2s ease, transform 0.2s ease;
}
.sg-dlp-head {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-bottom: 8px;
}
.sg-dlp-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: 600;
    color: #f0f6fc;
}
.sg-dlp-cancel,
.sg-dlp-close {
    flex-shrink: 0;
    padding: 0 2px;
    border: none;
    background: transparent;
    color: #8b949e;
    cursor: pointer;
    line-height: 1;
}
.sg-dlp-cancel {
    display: none;
    font-size: 11px;
    color: #f85149;
}
.sg-dlp-card.sg-dlp-can-cancel .sg-dlp-cancel {
    display: inline-block;
}
.sg-dlp-close {
    font-size: 16px;
}
.sg-dlp-close:hover,
.sg-dlp-cancel:hover {
    color: #f0f6fc;
}
.sg-dlp-bar {
    height: 6px;
    overflow: hidden;
    border-radius: 3px;
    background: #21262d;
}
.sg-dlp-fill {
    width: 0;
    height: 100%;
    border-radius: 3px;
    background: linear-gradient(90deg, #1f6feb, #2ea043);
    transition: width 0.2s ease;
}
.sg-dlp-card.sg-dlp-indeterminate .sg-dlp-fill {
    width: 35%;
    animation: sg-dlp-indeterminate 1.2s ease-in-out infinite;
}
@keyframes sg-dlp-indeterminate {
    0% { margin-left: -35%; }
    100% { margin-left: 100%; }
}
.sg-dlp-meta {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    margin-top: 6px;
    color: #8b949e;
    font-size: 11px;
}
.sg-dlp-pct {
    color: #58a6ff;
    font-weight: 600;
}
.sg-dlp-status {
    margin-top: 4px;
    overflow: hidden;
    color: #8b949e;
    font-size: 11px;
    text-overflow: ellipsis;
    white-space: nowrap;
}
.sg-dlp-card.sg-dlp-complete .sg-dlp-fill {
    background: #2ea043;
}
.sg-dlp-card.sg-dlp-complete .sg-dlp-pct {
    color: #3fb950;
}
.sg-dlp-card.sg-dlp-error .sg-dlp-fill {
    background: #da3633;
}
.sg-dlp-card.sg-dlp-error .sg-dlp-pct,
.sg-dlp-card.sg-dlp-error .sg-dlp-status {
    color: #f85149;
}
.sg-dlp-card.sg-dlp-error .sg-dlp-status {
    white-space: normal;
    word-break: break-all;
}
.sg-dlp-card.sg-dlp-cancelled .sg-dlp-fill {
    background: #6e7681;
}

/* ===== 注入下载按钮（绿色文字按钮） ===== */
.sg-dl-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 8px;
    border: 1px solid #2da44e;
    border-radius: 5px;
    background: transparent;
    color: #2da44e;
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    vertical-align: middle;
    margin-left: 6px;
    transition: all 0.15s;
    flex-shrink: 0;
    white-space: nowrap;
    line-height: 1.4;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
}
.sg-dl-btn:hover {
    background: #2da44e;
    color: #fff;
}
.sg-dl-btn svg {
    width: 12px;
    height: 12px;
    fill: currentColor;
    flex-shrink: 0;
}

/* ===== 下载弹窗 ===== */
#sg-download-modal {
    position: fixed;
    inset: 0;
    z-index: 2147483648;
    display: flex;
    align-items: center;
    justify-content: center;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.2s ease;
}
#sg-download-modal.sg-visible {
    opacity: 1;
    pointer-events: auto;
}
#sg-dm-overlay {
    position: absolute;
    inset: 0;
    background: rgba(0, 0, 0, 0.6);
}
#sg-dm-card {
    position: relative;
    width: 400px;
    max-height: 480px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 12px;
    box-shadow: 0 16px 48px rgba(0, 0, 0, 0.5);
    display: flex;
    flex-direction: column;
    transform: translateY(12px) scale(0.97);
    transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1);
    overflow: hidden;
}
#sg-download-modal.sg-visible #sg-dm-card {
    transform: translateY(0) scale(1);
}

/* 弹窗头部 */
.sg-dm-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 18px;
    border-bottom: 1px solid #21262d;
    flex-shrink: 0;
}
.sg-dm-header h4 {
    margin: 0;
    font-size: 14px;
    font-weight: 600;
    color: #ffffff;
    display: flex;
    align-items: center;
    gap: 8px;
}
.sg-dm-header h4 img, .sg-dm-header h4 .sg-dm-icon {
    width: 16px;
    height: 16px;
}
.sg-dm-refresh-btn {
    width: 28px;
    height: 28px;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: #8b949e;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s;
}
.sg-dm-refresh-btn:hover {
    background: #21262d;
    color: #e6edf3;
}
.sg-dm-refresh-btn svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
    transition: transform 0.3s;
}
.sg-dm-refresh-btn.sg-spin svg {
    animation: sg-spin 1s linear infinite;
}

/* 弹窗文件信息 */
.sg-dm-fileinfo {
    padding: 10px 18px;
    background: #161b22;
    border-bottom: 1px solid #21262d;
    font-size: 12px;
    color: #8b949e;
    flex-shrink: 0;
}
.sg-dm-fileinfo .sg-dm-filename {
    color: #e6edf3;
    font-weight: 500;
    font-size: 13px;
    word-break: break-all;
}

/* 弹窗节点列表 */
.sg-dm-nodelist {
    flex: 1;
    overflow-y: auto;
    padding: 6px 0;
}
.sg-dm-nodelist::-webkit-scrollbar {
    width: 6px;
}
.sg-dm-nodelist::-webkit-scrollbar-thumb {
    background: #30363d;
    border-radius: 3px;
}
.sg-dm-node-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 18px;
    transition: background 0.12s;
}
.sg-dm-node-item:hover {
    background: #161b22;
}
.sg-dm-domain {
    flex: 1;
    font-size: 13px;
    color: #e6edf3;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}
.sg-dm-node-delay {
    font-size: 11px;
    color: #8b949e;
    white-space: nowrap;
    min-width: 40px;
    text-align: right;
}
.sg-dm-node-delay.sg-dm-fast { color: #2da44e; }
.sg-dm-node-delay.sg-dm-medium { color: #d29922; }
.sg-dm-node-delay.sg-dm-slow { color: #f85149; }

.sg-dm-download-btn {
    padding: 4px 12px;
    border: 1px solid #2da44e;
    border-radius: 5px;
    background: transparent;
    color: #2da44e;
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    white-space: nowrap;
}
.sg-dm-download-btn:hover {
    background: #2da44e;
    color: #fff;
}

/* ===== 管理面板 Tab ===== */
.sg-tabs {
    display: flex;
    border-bottom: 1px solid #21262d;
    flex-shrink: 0;
}
.sg-tab {
    flex: 1;
    padding: 10px 0;
    text-align: center;
    font-size: 13px;
    color: #8b949e;
    cursor: pointer;
    border-bottom: 2px solid transparent;
    transition: all 0.15s;
    background: none;
    border-top: none;
    border-left: none;
    border-right: none;
}
.sg-tab:hover {
    color: #e6edf3;
    background: #161b22;
}
.sg-tab.sg-active {
    color: #e6edf3;
    border-bottom-color: #2da44e;
}

.sg-tab-content {
    display: none;
    overflow-y: auto;
    flex: 1;
}
.sg-tab-content.sg-active {
    display: flex;
    flex-direction: column;
}

/* 注入设置区域 */
.sg-inject-setting {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 20px;
    border-bottom: 1px solid #21262d;
    font-size: 13px;
}
.sg-inject-setting:last-child {
    border-bottom: none;
}
.sg-inject-label {
    display: flex;
    flex-direction: column;
    gap: 2px;
}
.sg-inject-label .sg-label-title {
    color: #e6edf3;
    font-weight: 500;
}
.sg-inject-label .sg-label-desc {
    color: #6e7681;
    font-size: 11px;
}

/* ===== 开关（增强样式） ===== */
.sg-toggle {
    position: relative;
    width: 40px;
    height: 22px;
    cursor: pointer;
    display: inline-block;
    flex-shrink: 0;
}
.sg-toggle input {
    position: absolute;
    opacity: 0;
    width: 100%;
    height: 100%;
    cursor: pointer;
    margin: 0;
    z-index: 1;
}
.sg-toggle .sg-toggle-track {
    width: 40px;
    height: 22px;
    border-radius: 11px;
    background: #30363d;
    transition: background 0.25s;
    position: relative;
    box-shadow: inset 0 1px 3px rgba(0, 0, 0, 0.3);
}
.sg-toggle input:checked + .sg-toggle-track {
    background: #2da44e;
    box-shadow: inset 0 1px 3px rgba(0, 0, 0, 0.2), 0 0 0 2px rgba(45, 164, 78, 0.2);
}
.sg-toggle .sg-toggle-track::after {
    content: '';
    position: absolute;
    width: 16px;
    height: 16px;
    border-radius: 50%;
    background: #fff;
    top: 3px;
    left: 3px;
    transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
}
.sg-toggle input:checked + .sg-toggle-track::after {
    transform: translateX(18px);
}
/* 开关状态文字 */
.sg-toggle-status {
    font-size: 11px;
    margin-left: 6px;
    flex-shrink: 0;
}
.sg-toggle-status.sg-on {
    color: #2da44e;
}
.sg-toggle-status.sg-off {
    color: #6e7681;
}

/* ===== 底部 footer ===== */
.sg-footer {
    padding: 8px 16px;
    border-top: 1px solid #21262d;
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 11px;
    color: #484f58;
    flex-shrink: 0;
    background: #010409;
}
.sg-footer a {
    color: #8b949e;
    text-decoration: none;
    transition: color 0.15s;
}
.sg-footer a:hover {
    color: #58a6ff;
}
`);

	// ===== 注入 UI =====
	function injectUI() {
		// 浮动按钮
		const fab = document.createElement('button');
		fab.id = 'supergit-fab';
		fab.title = 'SuperGit镜像节点管理';
		const fabImg = document.createElement('img');
		fabImg.src = ICON_URI;
		fabImg.alt = 'SuperGit';
		fabImg.style.cssText = 'width:32px;height:32px;';
		fab.appendChild(fabImg);
		document.body.appendChild(fab);

		// 遮罩
		const overlay = document.createElement('div');
		overlay.id = 'supergit-overlay';
		document.body.appendChild(overlay);

		// 管理面板
		const panel = document.createElement('div');
		panel.id = 'supergit-panel';
		panel.innerHTML = buildPanelHTML();
		document.body.appendChild(panel);

		if (allNodes.length > 0) fab.classList.add('sg-pulse');

		// 下载弹窗
		const modal = document.createElement('div');
		modal.id = 'sg-download-modal';
		modal.innerHTML = buildModalHTML();
		document.body.appendChild(modal);
	}

	function buildPanelHTML() {
		const scenariosHTML = Object.entries(INJECT_SCENARIOS).map(([key, cfg]) => {
			const checked = injectConfig[key] ? 'checked' : '';
			const statusClass = injectConfig[key] ? 'sg-on' : 'sg-off';
			const statusText = injectConfig[key] ? '已开启' : '已关闭';
			return `
                <div class="sg-inject-setting">
                    <div class="sg-inject-label">
                        <span class="sg-label-title">${cfg.label}</span>
                        <span class="sg-label-desc">${cfg.desc}</span>
                    </div>
                    <div style="display:flex;align-items:center;">
                        <label class="sg-toggle">
                            <input type="checkbox" class="sg-inject-cb" data-key="${key}" ${checked}>
                            <span class="sg-toggle-track"></span>
                        </label>
                        <span class="sg-toggle-status ${statusClass}" data-status-for="${key}">${statusText}</span>
                    </div>
                </div>`;
		}).join('');

		return `
            <div class="sg-panel-header">
                <h3><img src="${ICON_URI}" style="width:20px;height:20px;"> SuperGit镜像节点管理</h3>
                <button class="sg-close-btn" id="sg-close-btn">
                    <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M3.72 3.72a.75.75 0 011.06 0L8 6.94l3.22-3.22a.75.75 0 111.06 1.06L9.06 8l3.22 3.22a.75.75 0 11-1.06 1.06L8 9.06l-3.22 3.22a.75.75 0 01-1.06-1.06L6.94 8 3.72 4.78a.75.75 0 010-1.06z"/></svg>
                </button>
            </div>
            <div class="sg-tabs">
                <button class="sg-tab sg-active" data-tab="nodes">节点管理</button>
                <button class="sg-tab" data-tab="inject">下载按钮</button>
            </div>
            <!-- Tab: 节点管理 -->
            <div class="sg-tab-content sg-active" id="sg-tab-nodes">
                <div class="sg-status-bar">
                    <span class="sg-status-dot" id="sg-dot"></span>
                    <span id="sg-status-text">加载中...</span>
                    <span class="sg-last-update" id="sg-last-update"></span>
                </div>
                <div class="sg-toolbar">
                    <button class="sg-toolbar-btn" id="sg-refresh-btn">
                        <svg viewBox="0 0 24 24"><path d="M17.65 6.35A7.958 7.958 0 0012 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0112 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
                        <span>刷新节点</span>
                    </button>
                    <button class="sg-toolbar-btn" id="sg-select-all-btn">全选</button>
                    <button class="sg-toolbar-btn" id="sg-deselect-all-btn">全不选</button>
                    <button class="sg-toolbar-btn" id="sg-top10-btn">默认 Top10</button>
                </div>
                <div class="sg-node-list" id="sg-node-list"></div>
            </div>
            <!-- Tab: 下载按钮配置 -->
            <div class="sg-tab-content" id="sg-tab-inject">
                <div style="padding:10px 20px 6px;font-size:12px;color:#8b949e;border-bottom:1px solid #21262d;">
                    管理各位置下载按钮的显示，关闭后需刷新页面生效。
                </div>
                ${scenariosHTML}
            </div>
            <div class="sg-footer">
                <span>${VERSION}</span>
                <a href="https://hsya.top/" target="_blank" rel="noopener">划水鸭</a>
            </div>`;
	}

	function buildModalHTML() {
		return `
            <div id="sg-dm-overlay"></div>
            <div id="sg-dm-card">
                <div class="sg-dm-header">
                    <h4><img src="${ICON_URI}"> 镜像加速下载</h4>
                    <div style="display:flex;align-items:center;gap:6px;">
                        <button class="sg-dm-refresh-btn" id="sg-dm-refresh-btn" title="刷新节点">
                            <svg width="14" height="14" viewBox="0 0 24 24"><path d="M17.65 6.35A7.958 7.958 0 0012 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0112 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
                        </button>
                        <button class="sg-close-btn" id="sg-dm-close">
                            <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M3.72 3.72a.75.75 0 011.06 0L8 6.94l3.22-3.22a.75.75 0 111.06 1.06L9.06 8l3.22 3.22a.75.75 0 11-1.06 1.06L8 9.06l-3.22 3.22a.75.75 0 01-1.06-1.06L6.94 8 3.72 4.78a.75.75 0 010-1.06z"/></svg>
                        </button>
                    </div>
                </div>
                <div class="sg-dm-fileinfo">
                    <div style="margin-bottom:4px;">下载文件</div>
                    <div class="sg-dm-filename" id="sg-dm-filename">-</div>
                </div>
                <div class="sg-dm-nodelist" id="sg-dm-nodelist"></div>
                <div class="sg-footer">
                    <span>${VERSION}</span>
                    <a href="https://hsya.top/" target="_blank" rel="noopener">划水鸭</a>
                </div>
            </div>`;
	}

	// ===== 面板切换 =====
	function togglePanel() {
		const panel = document.getElementById('supergit-panel');
		const overlay = document.getElementById('supergit-overlay');
		const fab = document.getElementById('supergit-fab');
		panelOpen = !panelOpen;
		fab.classList.remove('sg-pulse');
		panel.classList.toggle('sg-visible', panelOpen);
		overlay.classList.toggle('sg-visible', panelOpen);
		if (panelOpen) refreshNodeList();
	}

	// ===== 绑定事件 =====
	function bindEvents() {
		const fab = document.getElementById('supergit-fab');
		const overlay = document.getElementById('supergit-overlay');

		fab.addEventListener('click', togglePanel);
		overlay.addEventListener('click', togglePanel);
		document.getElementById('sg-close-btn').addEventListener('click', togglePanel);

		// Tab 切换
		const panel = document.getElementById('supergit-panel');
		panel.querySelectorAll('.sg-tab').forEach(tab => {
			tab.addEventListener('click', () => {
				panel.querySelectorAll('.sg-tab').forEach(t => t.classList.remove('sg-active'));
				panel.querySelectorAll('.sg-tab-content').forEach(c => c.classList.remove(
					'sg-active'));
				tab.classList.add('sg-active');
				document.getElementById('sg-tab-' + tab.dataset.tab).classList.add('sg-active');
			});
		});

		// 注入配置 checkbox
		panel.querySelectorAll('.sg-inject-cb').forEach(cb => {
			cb.addEventListener('change', () => {
				const key = cb.dataset.key;
				injectConfig[key] = cb.checked;
				saveInjectConfig();
				const statusEl = document.querySelector(`[data-status-for="${key}"]`);
				if (statusEl) {
					statusEl.textContent = cb.checked ? '已开启' : '已关闭';
					statusEl.className = 'sg-toggle-status ' + (cb.checked ? 'sg-on' : 'sg-off');
				}
				showToast(cb.checked ? '已开启，刷新页面后生效' : '已关闭，刷新页面后生效');
			});
		});

		// 刷新节点
		document.getElementById('sg-refresh-btn').addEventListener('click', refreshNodes);

		// 全选 / 全不选 / 默认 Top10
		document.getElementById('sg-select-all-btn').addEventListener('click', () => {
			visibleKeys = allNodes.map(n => nodeKey(n));
			saveVisibleKeys();
			refreshNodeList();
			showToast('已全选所有节点');
		});
		document.getElementById('sg-deselect-all-btn').addEventListener('click', () => {
			visibleKeys = [];
			saveVisibleKeys();
			refreshNodeList();
			showToast('已取消所有节点');
		});
		document.getElementById('sg-top10-btn').addEventListener('click', () => {
			visibleKeys = allNodes.slice(0, 10).map(n => nodeKey(n));
			saveVisibleKeys();
			refreshNodeList();
			showToast('已恢复默认 Top10 节点');
		});

		// 节点列表委托
		document.getElementById('sg-node-list').addEventListener('change', (e) => {
			if (!e.target.classList.contains('sg-node-cb')) return;
			const key = e.target.dataset.key;
			if (e.target.checked) {
				if (!visibleKeys.includes(key)) visibleKeys.push(key);
			} else {
				visibleKeys = visibleKeys.filter(k => k !== key);
			}
			saveVisibleKeys();
		});
		document.getElementById('sg-node-list').addEventListener('click', (e) => {
			const btn = e.target.closest('.sg-test-btn');
			if (btn) testNode(btn.dataset.url, btn);
		});

		// 下载弹窗事件
		const modal = document.getElementById('sg-download-modal');
		document.getElementById('sg-dm-close').addEventListener('click', () => modal.classList.remove(
			'sg-visible'));
		document.getElementById('sg-dm-overlay').addEventListener('click', () => modal.classList.remove(
			'sg-visible'));

		// 弹窗刷新按钮
		document.getElementById('sg-dm-refresh-btn').addEventListener('click', () => {
			const refreshEl = document.getElementById('sg-dm-refresh-btn');
			refreshEl.classList.add('sg-spin');
			loadMirrorNodes('手动').then(() => {
				// 获取当前弹窗中的 githubUrl 并重新渲染
				const firstBtn = document.querySelector('.sg-dm-download-btn');
				const ghUrl = firstBtn ? firstBtn.dataset.ghUrl : '';
				renderModalNodeList(ghUrl);
				refreshEl.classList.remove('sg-spin');
				showToast('节点已刷新');
			}).catch(() => {
				refreshEl.classList.remove('sg-spin');
				showToast('刷新失败');
			});
		});

		document.getElementById('sg-dm-nodelist').addEventListener('click', (e) => {
			try {
				const btn = e.target.closest('.sg-dm-download-btn');
				if (!btn) return;
				const ghUrl = btn.dataset.ghUrl;
				const nodeUrl = btn.dataset.nodeUrl;
				if (!ghUrl || !nodeUrl) return;
				if (isPrivateRepo(ghUrl)) {
					modal.classList.remove('sg-visible');
					showPrivateRepoNotice();
					return;
				}
				const url = mirrorUrl(ghUrl, nodeUrl);
				if (!url) return;
				downloadViaMirror(url);
				showToast('开始下载...');
				modal.classList.remove('sg-visible');
			} catch (err) {
				console.error('[SuperGit] 下载出错:', err);
				showToast('下载出错: ' + (err.message || '未知错误'));
			}
		});
	}

	// ===== 下载进度显示 =====
	const DOWNLOAD_TASKS = new Map();
	let downloadTaskSeq = 0;

	function escapeHtml(text) {
		return String(text).replace(/[&<>"']/g, ch => ({
			'&': '&amp;',
			'<': '&lt;',
			'>': '&gt;',
			'"': '&quot;',
			"'": '&#39;'
		}[ch]));
	}

	function formatBytes(bytes) {
		if (!Number.isFinite(bytes) || bytes < 0) return '—';
		if (bytes < 1024) return `${Math.round(bytes)} B`;
		const units = ['KB', 'MB', 'GB', 'TB'];
		let value = bytes / 1024;
		let unit = 0;
		while (value >= 1024 && unit < units.length - 1) {
			value /= 1024;
			unit += 1;
		}
		const digits = value >= 100 ? 0 : value >= 10 ? 1 : 2;
		return `${value.toFixed(digits)} ${units[unit]}`;
	}

	function formatSpeed(bytesPerSecond) {
		if (!Number.isFinite(bytesPerSecond) || bytesPerSecond <= 0) return '';
		return `${formatBytes(bytesPerSecond)}/s`;
	}

	function formatDuration(seconds) {
		if (!Number.isFinite(seconds) || seconds <= 0) return '';
		seconds = Math.round(seconds);
		if (seconds < 60) return `${seconds} 秒`;
		const minutes = Math.floor(seconds / 60);
		const rest = seconds % 60;
		if (minutes < 60) return `${minutes} 分 ${rest} 秒`;
		return `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
	}

	function getDownloadName(url) {
		try {
			const u = new URL(url, location.href);
			const raw = u.pathname.split('/').filter(Boolean).pop() || 'download';
			return decodeURIComponent(raw).replace(/[\\/:*?"<>|]+/g, '-').trim() || 'download';
		} catch {
			return 'download';
		}
	}

	function ensureDownloadProgressContainer() {
		let box = document.getElementById('sg-download-progress');
		if (!box) {
			box = document.createElement('div');
			box.id = 'sg-download-progress';
			document.body.appendChild(box);
		}
		return box;
	}

	function createDownloadTask(url, name) {
		const box = ensureDownloadProgressContainer();
		const id = `sg-dlp-${Date.now()}-${++downloadTaskSeq}`;
		const card = document.createElement('div');
		card.className = 'sg-dlp-card';
		card.id = id;
		card.innerHTML = `
            <div class="sg-dlp-head">
                <span class="sg-dlp-name" title="${escapeHtml(name)}">${escapeHtml(name)}</span>
                <button type="button" class="sg-dlp-cancel" title="取消下载">取消</button>
                <button type="button" class="sg-dlp-close" title="隐藏进度">×</button>
            </div>
            <div class="sg-dlp-bar"><div class="sg-dlp-fill"></div></div>
            <div class="sg-dlp-meta">
                <span class="sg-dlp-pct">准备中…</span>
                <span class="sg-dlp-size">—</span>
            </div>
            <div class="sg-dlp-status">等待下载开始…</div>`;
		box.appendChild(card);

		const task = {
			id,
			url,
			name,
			card,
			loaded: 0,
			total: 0,
			speed: 0,
			lastTime: 0,
			lastLoaded: 0,
			sampled: false,
			status: 'preparing',
			detail: '',
			noProgress: false,
			finished: false,
			cancelled: false,
			hidden: false,
			canCancel: false,
			download: null,
			raf: 0,
			stallTimer: 0,
			removeTimer: 0
		};
		DOWNLOAD_TASKS.set(id, task);

		card.querySelector('.sg-dlp-close').addEventListener('click', () => {
			removeDownloadTask(task);
		});
		card.querySelector('.sg-dlp-cancel').addEventListener('click', () => {
			cancelDownloadTask(task);
		});

		task.stallTimer = setTimeout(() => {
			if (task.status === 'preparing' && !task.finished) {
				task.status = 'downloading';
				task.noProgress = true;
				scheduleDownloadRender(task);
			}
		}, 2000);

		return task;
	}

	function scheduleDownloadRender(task) {
		if (!task || task.hidden || task.raf) return;
		task.raf = requestAnimationFrame(() => {
			task.raf = 0;
			renderDownloadTask(task);
		});
	}

	function renderDownloadTask(task) {
		if (!task || !task.card || !task.card.isConnected) return;
		const card = task.card;
		const fill = card.querySelector('.sg-dlp-fill');
		const pctEl = card.querySelector('.sg-dlp-pct');
		const sizeEl = card.querySelector('.sg-dlp-size');
		const statusEl = card.querySelector('.sg-dlp-status');
		const indeterminate = task.status === 'downloading' && !task.total;
		const pct = task.total > 0 ? Math.min(100, (task.loaded / task.total) * 100) : 0;

		card.classList.toggle('sg-dlp-indeterminate', indeterminate);
		card.classList.toggle('sg-dlp-complete', task.status === 'complete');
		card.classList.toggle('sg-dlp-error', task.status === 'error');
		card.classList.toggle('sg-dlp-cancelled', task.status === 'cancelled');
		card.classList.toggle('sg-dlp-can-cancel', task.status === 'downloading' && task.canCancel);

		if (task.status === 'complete') {
			fill.style.width = '100%';
			pctEl.textContent = '100%';
			sizeEl.textContent = formatBytes(task.total || task.loaded);
			statusEl.textContent = '下载完成';
			return;
		}

		if (task.status === 'error') {
			fill.style.width = task.total > 0 ? `${pct.toFixed(1)}%` : '100%';
			pctEl.textContent = task.total > 0 ? `${pct.toFixed(1)}%` : '失败';
			sizeEl.textContent = task.total > 0 ? `${formatBytes(task.loaded)} / ${formatBytes(task.total)}` :
				(task.loaded ? formatBytes(task.loaded) : '');
			statusEl.textContent = `下载失败${task.detail ? `：${task.detail}` : ''}`;
			return;
		}

		if (task.status === 'cancelled') {
			fill.style.width = task.total > 0 ? `${pct.toFixed(1)}%` : '0%';
			pctEl.textContent = '已取消';
			sizeEl.textContent = task.loaded ? formatBytes(task.loaded) : '';
			statusEl.textContent = '下载已取消';
			return;
		}

		fill.style.width = task.total > 0 ? `${pct.toFixed(1)}%` : '';
		pctEl.textContent = task.status === 'preparing' ? '准备中…' : (task.total > 0 ? `${pct.toFixed(1)}%` : '下载中');
		sizeEl.textContent = task.status === 'preparing' ? '—' : (task.total > 0 ?
			`${formatBytes(task.loaded)} / ${formatBytes(task.total)}` : `已下载 ${formatBytes(task.loaded)}`);

		if (task.status === 'preparing') {
			statusEl.textContent = '等待下载开始…';
		} else if (task.noProgress) {
			statusEl.textContent = '下载中…（等待进度）';
		} else {
			const parts = [];
			if (task.speed > 0) parts.push(formatSpeed(task.speed));
			if (task.total > task.loaded && task.speed > 0) {
				parts.push(`剩余 ${formatDuration((task.total - task.loaded) / task.speed)}`);
			}
			statusEl.textContent = parts.length ? parts.join(' · ') : '下载中…';
		}
	}

	function updateDownloadTask(task, event) {
		if (!task || task.finished || task.cancelled || task.hidden) return;
		const loadedCandidates = [event?.loaded, event?.bytesReceived, event?.downloaded];
		let loaded = NaN;
		for (const value of loadedCandidates) {
			if (value === undefined || value === null || value === '') continue;
			const n = Number(value);
			if (Number.isFinite(n)) {
				loaded = n;
				break;
			}
		}
		let total = 0;
		const totalCandidates = [event?.total, event?.totalSize, event?.fileSize, event?.contentLength];
		for (const value of totalCandidates) {
			if (value === undefined || value === null || value === '') continue;
			const n = Number(value);
			if (Number.isFinite(n) && n > 0) {
				total = n;
				break;
			}
		}
		if (Number.isFinite(loaded)) task.loaded = Math.max(0, loaded);
		if (total > 0) task.total = total;

		const now = performance.now();
		if (!task.sampled) {
			task.sampled = true;
			task.lastTime = now;
			task.lastLoaded = task.loaded;
		} else {
			const elapsed = (now - task.lastTime) / 1000;
			if (elapsed >= 0.4) {
				const delta = task.loaded - task.lastLoaded;
				const instant = delta > 0 ? delta / elapsed : 0;
				task.speed = task.speed > 0 ? task.speed * 0.7 + instant * 0.3 : instant;
				task.lastTime = now;
				task.lastLoaded = task.loaded;
			}
		}

		task.status = 'downloading';
		task.noProgress = false;
		scheduleDownloadRender(task);
	}

	function finishDownloadTask(task, status, detail) {
		if (!task || task.finished) return;
		task.finished = true;
		clearTimeout(task.stallTimer);
		if (task.raf) {
			cancelAnimationFrame(task.raf);
			task.raf = 0;
		}
		task.status = status;
		task.detail = detail || '';
		task.speed = 0;
		task.canCancel = false;
		if (status === 'complete' && !task.total) task.total = task.loaded;
		renderDownloadTask(task);

		if (status === 'complete') {
			task.removeTimer = setTimeout(() => removeDownloadTask(task), 8000);
		} else if (status === 'cancelled') {
			task.removeTimer = setTimeout(() => removeDownloadTask(task), 3000);
		}
	}

	function cancelDownloadTask(task) {
		if (!task || task.finished) return;
		task.cancelled = true;
		try {
			task.download?.abort?.();
		} catch (e) {
			console.warn('[SuperGit] 取消下载失败:', e);
		}
		finishDownloadTask(task, 'cancelled');
	}

	function removeDownloadTask(task) {
		if (!task) return;
		task.hidden = true;
		clearTimeout(task.stallTimer);
		clearTimeout(task.removeTimer);
		if (task.raf) {
			cancelAnimationFrame(task.raf);
			task.raf = 0;
		}
		DOWNLOAD_TASKS.delete(task.id);
		const card = task.card;
		if (!card) return;
		card.classList.add('sg-dlp-leaving');
		setTimeout(() => {
			card.remove();
			const box = document.getElementById('sg-download-progress');
			if (box && !box.children.length) box.remove();
		}, 200);
	}

	// ===== 下载 (GM_download + GM_openInTab 降级) =====
	function downloadViaMirror(url) {
		if (!url) return;
		const name = getDownloadName(url);
		const task = createDownloadTask(url, name);

		try {
			const download = GM_download({
				url: url,
				name: name,
				saveAs: false,
				onprogress: (e) => updateDownloadTask(task, e),
				onload: (e) => {
					if (task.cancelled) return;
					updateDownloadTask(task, e);
					finishDownloadTask(task, 'complete');
				},
				onerror: (err) => {
					if (task.cancelled) return;
					console.error('[SuperGit] GM_download 失败，使用新标签页:', err);
					finishDownloadTask(task, 'error', err?.error || err?.message || '未知错误');
					GM_openInTab(url, { active: false, insert: true });
				},
				ontimeout: () => {
					if (task.cancelled) return;
					console.error('[SuperGit] GM_download 超时');
					finishDownloadTask(task, 'error', '下载超时');
					GM_openInTab(url, { active: false, insert: true });
				}
			});
			task.download = download;
			if (download && typeof download.abort === 'function') {
				task.canCancel = true;
				scheduleDownloadRender(task);
			}
		} catch (e) {
			console.warn('[SuperGit] GM_download 异常，使用新标签页:', e);
			finishDownloadTask(task, 'error', e?.message || '脚本管理器不支持下载');
			GM_openInTab(url, { active: false, insert: true });
		}
	}

	// ===== 打开下载弹窗 =====
	function openDownloadModal(githubUrl, filename) {
		const modal = document.getElementById('sg-download-modal');
		document.getElementById('sg-dm-filename').textContent = filename || githubUrl;

		const visibleNodes = visibleKeys.length ? allNodes.filter(n => visibleKeys.includes(nodeKey(n))) : allNodes
			.slice(0, 10);
		const listEl = document.getElementById('sg-dm-nodelist');

		if (!visibleNodes.length) {
			listEl.innerHTML =
				'<div class="sg-empty">暂无可用节点<br>正在自动刷新...<br><small style="color:#484f58;margin-top:4px;">也可点击右上角刷新按钮</small></div>';
			if (!_autoRefreshing) {
				autoRefreshNodes(() => {
					renderModalNodeList(githubUrl);
				});
			}
		} else {
			renderModalNodeList(githubUrl);
		}

		modal.classList.add('sg-visible');
	}

	function renderModalNodeList(githubUrl) {
		const listEl = document.getElementById('sg-dm-nodelist');
		const visibleNodes = visibleKeys.length ? allNodes.filter(n => visibleKeys.includes(nodeKey(n))) : allNodes
			.slice(0, 10);

		if (!visibleNodes.length) {
			listEl.innerHTML =
				'<div class="sg-empty">暂无可用节点<br><small style="color:#484f58;margin-top:4px;">点击右上角刷新按钮重试</small></div>';
			return;
		}
		listEl.innerHTML = visibleNodes.map(node => {
			const lat = node.latency || 0;
			const cls = dmDelayClass(lat);
			return `
                <div class="sg-dm-node-item">
                    <span class="sg-dm-domain" title="${node.url}">${shortDomain(node.url)}</span>
                    <span class="sg-dm-node-delay ${cls}">${lat}ms</span>
                    <button class="sg-dm-download-btn" data-gh-url="${githubUrl}" data-node-url="${node.url}">下载</button>
                </div>`;
		}).join('');
	}

	// ===== 注入下载按钮到 GitHub 页面 =====
	let injectTimer = null;

	function setupInject() {
		const anyEnabled = Object.values(injectConfig).some(v => v);
		if (!anyEnabled) return;

		scheduleInject();

		// GitHub 是 SPA，监听路由变化重新注入
		let lastUrl = location.href;
		const observer = new MutationObserver((mutations) => {
			if (location.href !== lastUrl) {
				lastUrl = location.href;
				scheduleInject(800);
			} else {
				const hasRelevant = mutations.some(m => {
					const target = m.target;
					if (target.closest?.(
							'details, .dropdown-menu, .js-menu-container, [data-view-component]'))
						return true;
					for (const node of m.addedNodes) {
						if (node.nodeType !== 1) continue;
						const html = (node.outerHTML || node.textContent || '').toLowerCase();
						if (html.includes('download') || html.includes('release') || html.includes(
								'archive') || html.includes('raw') || html.includes('codeload'))
							return true;
					}
					return false;
				});
				if (hasRelevant) scheduleInject(300);
			}
		});
		observer.observe(document.body, {
			childList: true,
			subtree: true
		});

		setInterval(() => scheduleInject(), 5000);
	}

	function scheduleInject(delay) {
		clearTimeout(injectTimer);
		injectTimer = setTimeout(injectDownloadButtons, delay || 500);
	}

	function createDlBtn(githubUrl, filename) {
		const btn = document.createElement('button');
		btn.className = 'sg-dl-btn';
		btn.title = '镜像下载';
		btn.dataset.sgDlUrl = githubUrl;
		btn.setAttribute('aria-label', '镜像下载');
		btn.innerHTML = DL_SVG + '镜像下载';
		btn.addEventListener('click', (e) => {
			e.preventDefault();
			e.stopPropagation();
			if (isPrivateRepo(githubUrl)) {
				showPrivateRepoNotice();
				return;
			}
			openDownloadModal(githubUrl, filename || '');
		});
		return btn;
	}

	function tryInject(container, link, filename) {
		if (!container || container.querySelector('.sg-dl-btn')) return;
		if (!link || !link.href) return;
		const href = link.href;
		if (!href.includes('github.com') && !href.includes('githubusercontent.com') && !href.includes(
				'codeload.github.com')) return;
		const fname = filename || link.textContent.trim() || href.split('/').pop();
		container.appendChild(createDlBtn(href, fname));
	}

	function injectDownloadButtons() {
		const host = location.hostname;

		// ===== 1. Release 源码压缩包 =====
		if (injectConfig['release-zip']) {
			document.querySelectorAll(
				'a[href*="codeload.github.com"], a[href*="/archive/refs/"], a[href*="/zipball/"], a[href*="/tarball/"]'
			).forEach(link => {
				if (link.closest('.sg-dl-btn')) return;
				const parent = link.closest('li, .Box-row, div, tr, .liststyle-none') || link.parentElement;
				tryInject(parent, link, link.textContent.trim() || 'Source code');
			});
			document.querySelectorAll('section[class*="release"], .release, [data-test-id="release-body"]').forEach(
				section => {
					section.querySelectorAll('a[href*="/archive/"]').forEach(link => {
						const parent = link.closest('li, .Box-row, div') || link.parentElement;
						tryInject(parent, link);
					});
				});
		}

		// ===== 2. Release 附件 =====
		if (injectConfig['release-asset']) {
			document.querySelectorAll('a[href*="/releases/download/"]').forEach(link => {
				if (link.closest('.sg-dl-btn')) return;
				const row = link.closest('.Box-row, li, tr, div');
				if (row) tryInject(row, link);
				else tryInject(link.parentElement, link);
			});
			document.querySelectorAll('a[href*="/releases/expanded_assets/"]').forEach(link => {
				const row = link.closest('li, .Box-row, div');
				if (row) tryInject(row, link);
			});
		}

		// ===== 3. Raw 原始文件 =====
		if (injectConfig['raw-file']) {
			document.querySelectorAll('#raw-url, a[id="raw-url"]').forEach(link => {
				tryInject(link.parentElement, link);
			});
			document.querySelectorAll(
				'.js-blob-dropdown-content a[href*="raw"], .btn-group a[href*="/raw/"], a[href*="/raw/"][href*="githubusercontent.com"]'
			).forEach(link => {
				tryInject(link.parentElement, link);
			});
			document.querySelectorAll('a[role="menuitem"][href*="/raw/"], a[data-ga-click*="raw"]').forEach(
				link => {
					tryInject(link.parentElement, link);
				});
		}

		// ===== 4. Clone 弹框 Download ZIP =====
		if (injectConfig['clone-zip']) {
			document.querySelectorAll('details a[href*="codeload.github.com"], details a[href*="/archive/refs/"]')
				.forEach(link => {
					const details = link.closest('details');
					if (!details) return;
					const isClone = details.querySelector('[class*="clone"], input[value*="git clone"]');
					if (!isClone) return;
					const li = link.closest('li') || link.parentElement;
					tryInject(li, link, 'Download ZIP');
				});
			document.querySelectorAll('[data-view-component] a[href*="codeload.github.com"]').forEach(link => {
				const container = link.closest('[data-view-component]');
				if (!container) return;
				const li = link.closest('li, div') || link.parentElement;
				tryInject(li, link, 'Download ZIP');
			});
		}

		// ===== 5. 仓库主页 Code 按钮 =====
		if (injectConfig['repo-archive']) {
			document.querySelectorAll(
				'details[data-view-component] a[href*="codeload.github.com"], details[data-view-component] a[href*="/archive/refs/"]'
			).forEach(link => {
				const li = link.closest('li, .liststyle-none, div') || link.parentElement;
				tryInject(li, link, 'Source code');
			});
			document.querySelectorAll('a[data-ga-click*="download"]').forEach(link => {
				const li = link.closest('li') || link.parentElement;
				tryInject(li, link, 'Source code');
			});
		}

		// ===== 6. LFS 大文件 =====
		if (injectConfig['lfs-file']) {
			document.querySelectorAll('a[href*="/info/lfs/objects/"], .lfs-object').forEach(link => {
				const parent = link.closest('li, div, tr, .Box-row') || link.parentElement;
				tryInject(parent, link);
			});
			document.querySelectorAll('table a[href*="lfs"]').forEach(link => {
				const tr = link.closest('tr');
				if (tr) tryInject(tr, link);
			});
		}

		// ===== 7. Gist 原始文件 =====
		if (host === 'gist.github.com' && injectConfig['gist-raw']) {
			document.querySelectorAll('.gist a[href*="/raw/"], .gist .btn[href*="raw"]').forEach(link => {
				tryInject(link.parentElement, link);
			});
		}

		// ===== 8. Compare/Diff 补丁下载 =====
		if (injectConfig['compare-diff']) {
			document.querySelectorAll('a[href*=".patch"], a[href*=".diff"]').forEach(link => {
				const parent = link.closest('li, div, .Box-row, .dropdown-item') || link.parentElement;
				tryInject(parent, link, link.textContent.trim() || 'Patch');
			});
		}

		// ===== 通用兜底 =====
		document.querySelectorAll('a[download][href*="github"]').forEach(link => {
			const parent = link.closest('li, div, .Box-row, tr') || link.parentElement;
			tryInject(parent, link);
		});
	}

	// ===== 刷新节点 =====
	async function refreshNodes() {
		const btn = document.getElementById('sg-refresh-btn');
		btn.classList.add('sg-loading');
		btn.querySelector('svg').classList.add('sg-spin');
		await loadMirrorNodes('手动');
		const validKeys = new Set(allNodes.map(n => nodeKey(n)));
		visibleKeys = visibleKeys.filter(k => validKeys.has(k));
		if (!visibleKeys.length && allNodes.length) visibleKeys = allNodes.slice(0, 10).map(n => nodeKey(n));
		saveVisibleKeys();
		refreshNodeList();
		btn.classList.remove('sg-loading');
		btn.querySelector('svg').classList.remove('sg-spin');
		showToast(`已刷新，共 ${allNodes.length} 个节点`);
	}

	// ===== 渲染节点列表 =====
	function refreshNodeList() {
		const listEl = document.getElementById('sg-node-list');
		const statusDot = document.getElementById('sg-dot');
		const statusText = document.getElementById('sg-status-text');

		if (allNodes.length > 0) {
			statusDot.className = 'sg-status-dot sg-online';
			const lats = allNodes.map(n => n.latency || 0);
			statusText.textContent =
				`${allNodes.length} 个节点 · 最低 ${Math.min(...lats)}ms · 平均 ${Math.round(lats.reduce((a, b) => a + b, 0) / lats.length)}ms`;
		} else {
			statusDot.className = 'sg-status-dot sg-offline';
			statusText.textContent = '暂无可用节点，正在自动刷新...';
		}
		document.getElementById('sg-last-update').textContent = new Date().toLocaleTimeString('zh-CN', {
			hour: '2-digit',
			minute: '2-digit'
		});

		if (!allNodes.length) {
			listEl.innerHTML = '<div class="sg-empty">暂无可用镜像节点<br>正在自动刷新...</div>';
			if (!_autoRefreshing) autoRefreshNodes();
			return;
		}
		listEl.innerHTML = allNodes.map(node => {
			const key = nodeKey(node);
			const checked = visibleKeys.includes(key) ? 'checked' : '';
			const lat = node.latency || 0;
			const cls = delayClass(lat);
			return `
                <div class="sg-node-item">
                    <label class="sg-checkbox">
                        <input type="checkbox" class="sg-node-cb" data-key="${key}" ${checked}>
                        <span class="sg-checkmark"></span>
                    </label>
                    <div class="sg-node-info">
                        <div class="sg-node-domain" title="${node.url}">${shortDomain(node.url)}</div>
                        <div class="sg-node-delay ${cls}">
                            <div class="sg-delay-bar"><div class="sg-delay-bar-fill" style="width:${delayPercent(lat)}%"></div></div>
                            <span class="sg-delay-text">${lat}ms</span>
                        </div>
                    </div>
                    <div class="sg-node-actions">
                        <button class="sg-test-btn" data-url="${node.url}">测速</button>
                    </div>
                </div>`;
		}).join('');
	}

	// ===== 单节点测速 =====
	function testNode(url, btnEl) {
		const orig = btnEl.textContent;
		btnEl.textContent = '...';
		btnEl.disabled = true;
		const start = performance.now();
		GM_xmlhttpRequest({
			method: 'GET',
			url: url,
			timeout: 5000,
			onload: () => {
				const ms = Math.round(performance.now() - start);
				btnEl.textContent = ms + 'ms';
				btnEl.style.color = '#2da44e';
				btnEl.style.borderColor = '#2da44e';
			},
			onerror: () => {
				btnEl.textContent = '超时';
				btnEl.style.color = '#f85149';
				btnEl.style.borderColor = '#f85149';
			},
			ontimeout: () => {
				btnEl.textContent = '超时';
				btnEl.style.color = '#f85149';
				btnEl.style.borderColor = '#f85149';
			},
			onfinally: () => {
				setTimeout(() => {
					btnEl.textContent = orig;
					btnEl.style.color = '';
					btnEl.style.borderColor = '';
					btnEl.disabled = false;
				}, 3000);
			}
		});
	}

	init();
})();