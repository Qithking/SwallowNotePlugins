/**
 * Export Plugin — 薄壳入口（宿主原语路线）
 *
 * 导出转换能力已内置宿主主程序（commands/export 模块）：DOCX/HTML 转换、
 * 图片读取、mermaid/katex/markmap 渲染、下载目录写入均在宿主命令中完成。
 * 本插件只保留 UI（工具栏下拉菜单 / toast / 导出锁），全部转换经
 * Tauri IPC 调用宿主命令，主题与渲染资源经 `window.__snExportBridge`
 * 调用宿主挂载的采集函数。
 *
 * 依赖的宿主命令（需宿主 ≥ 本次发版版本）：
 * - export_docx / export_html / generate_export_html / open_print_preview
 *
 * 宿主桥（main.tsx 挂载）：
 * - collectExportTheme()：采集当前主题导出值
 * - renderCustomBlocks(markdown, target)：渲染自定义代码块
 * - getWorkspaceRoot(notePath)：解析笔记所属工作区根
 */
/* eslint-disable react-refresh/only-export-components */
import { useState, useRef, useEffect, useCallback, type ReactNode } from 'react'
import type { PluginPanelProps, ToolbarButtonProps } from '@swallow-note/plugin-sdk'
import { definePlugin } from '@swallow-note/plugin-sdk'
// 导出 setHost 供宿主运行时安装 SDK overrides
export { setHost } from '@swallow-note/plugin-sdk'
import manifestJson from '../manifest.json'
import { invoke } from '@tauri-apps/api/core'
import { toast } from 'sonner'
import { compactMarkdown } from './markdown-normalize'
import { getStrings } from './i18n'

// ─── 宿主桥类型 ───

/** 与宿主 Rust ExportTheme 同形（camelCase，数值 px） */
interface ExportTheme {
  bodyFont: string
  bodySize: number
  lineHeight: number
  h1Size: number
  h2Size: number
  h3Size: number
  h4Size: number
  h5Size: number
  textColor: string
  linkColor: string
  borderColor: string
  codeFont: string
  codeSize: number
  codeBg: string
  quoteColor: string
  tableHeaderBg: string
}

/** 宿主 main.tsx 挂载的导出桥 */
interface SnExportBridge {
  collectExportTheme(): ExportTheme
  renderCustomBlocks(markdown: string, target: 'docx' | 'html'): Promise<Record<string, string>>
  getWorkspaceRoot(notePath: string): string | null
}

/** 宿主导出命令返回的落盘结果 */
interface HostExportResult {
  path: string
}

function getExportBridge(): SnExportBridge | null {
  const bridge = (window as unknown as { __snExportBridge?: SnExportBridge }).__snExportBridge
  return bridge && typeof bridge.collectExportTheme === 'function' ? bridge : null
}

/**
 * Read the user's current locale without depending on
 * `react-i18next`. We prefer the host's globally-injected locale
 * (`window.__SWALLOW_LOCALE__`) when present so we follow the
 * host's language switch in real time; otherwise we fall back to
 * the browser's `navigator.language` and finally to `zh-CN`.
 */
function readLocale(): string {
  const w = (typeof window !== 'undefined' ? (window as unknown as { __SWALLOW_LOCALE__?: string }) : undefined)
  if (w && typeof w.__SWALLOW_LOCALE__ === 'string' && w.__SWALLOW_LOCALE__.length > 0) {
    return w.__SWALLOW_LOCALE__
  }
  if (typeof navigator !== 'undefined' && typeof navigator.language === 'string') {
    return navigator.language
  }
  return 'zh-CN'
}

// ─── 图标组件 ───

function ExportIcon({ size = 18 }: { size?: number }): ReactNode {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <polyline points="7 10 12 15 17 10" />
      <line x1="12" y1="15" x2="12" y2="3" />
    </svg>
  )
}

// ─── Toolbar button component (dropdown menu) ────────────────────────────────

function ExportToolbarButton(props: ToolbarButtonProps): ReactNode {
  const {
    size,
    activeNoteContent,
    activeNotePath,
    activeNoteName,
    activeNoteExt,
  } = props
  const [menuOpen, setMenuOpen] = useState(false)
  // 导出锁：ref 做同步防抖（同一微任务内双击不重复触发），state 驱动 UI
  const exportingRef = useRef(false)
  const [isExporting, setIsExporting] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)
  const strings = getStrings(readLocale())

  const isMarkdown = activeNoteExt === 'md' || activeNoteExt === 'markdown'

  // Derive note name from path. Falls back to the full path so
  // the user always sees a meaningful filename. Prefers the
  // host-supplied `activeNoteName`（注意 `||` 链不可改三元，见旧版注释）
  const noteName = activeNoteName
    || activeNotePath.split('/').pop()
    || activeNotePath
    || 'untitled'

  const hasContent = activeNoteContent.trim().length > 0

  // Close menu on outside click.
  useEffect(() => {
    if (!menuOpen) return
    const handler = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setMenuOpen(false)
      }
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [menuOpen])

  /**
   * 导出流程统一脚手架：导出锁 → loading toast → produce() →
   * 成功 toast 展示宿主返回的最终落盘路径。保存对话框已移除
   * （方案 E：宿主固定写入系统下载目录，不接受任意路径）。
   */
  const runExport = useCallback(
    async (format: 'docx' | 'pdf' | 'html', produce: () => Promise<string>) => {
      if (exportingRef.current) return
      if (!hasContent) {
        toast.info(strings.emptyNote)
        return
      }
      const bridge = getExportBridge()
      if (!bridge) {
        toast.error(strings.exportFailed, {
          description:
            '当前宿主版本不支持导出原语（__snExportBridge 缺失），请升级 SwallowNote 主程序',
        })
        return
      }
      exportingRef.current = true
      setIsExporting(true)
      setMenuOpen(false)
      const toastId = toast.loading(strings.generating)
      try {
        const result = await produce()
        if (format === 'pdf') {
          // PDF 走打印预览窗口：用户在系统打印对话框中"存储为 PDF"
          toast.success(strings.previewOpened, { id: toastId })
        } else {
          toast.success(`${strings.exportSuccess}: ${result}`, { id: toastId })
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err)
        // 用户在保存对话框取消 —— 静默关闭 loading，不提示错误
        if (message.includes('__cancelled__')) {
          toast.dismiss(toastId)
          return
        }
        if (message.includes('Markdown too large') || message.includes('too large')) {
          toast.error(strings.tooLarge, { id: toastId, description: message })
        } else if (format === 'pdf') {
          toast.error(strings.pdfExportFailed, { id: toastId, description: message })
        } else if (format === 'html') {
          toast.error(strings.htmlExportFailed, { id: toastId, description: message })
        } else {
          toast.error(strings.exportFailed, { id: toastId, description: message })
        }
      } finally {
        exportingRef.current = false
        setIsExporting(false)
      }
    },
    [hasContent, strings],
  )

  /** 解析当前笔记的工作区根（宿主 fs_guard 图片读取白名单用） */
  const workspaceRoot = useCallback((): string | null => {
    const bridge = getExportBridge()
    return bridge?.getWorkspaceRoot(activeNotePath) ?? null
  }, [activeNotePath])

  const handleExportDocx = useCallback(async () => {
    const markdown = compactMarkdown(activeNoteContent)
    await runExport('docx', async () => {
      const bridge = getExportBridge()!
      // 采集主题（同步）→ 渲染自定义代码块为 PNG base64；
      // 图片读取已迁入宿主（note_path 解析相对路径），插件不再传 image_assets
      const theme = bridge.collectExportTheme()
      const renderedAssets = await bridge.renderCustomBlocks(markdown, 'docx')
      const result = await invoke<HostExportResult>('export_docx', {
        workspaceRoot: workspaceRoot(),
        notePath: activeNotePath,
        markdown,
        theme,
        renderedAssets,
        fileName: noteName,
      })
      return result.path
    })
  }, [activeNoteContent, activeNotePath, noteName, workspaceRoot, runExport])

  const handleExportPdf = useCallback(async () => {
    const markdown = compactMarkdown(activeNoteContent)
    await runExport('pdf', async () => {
      const bridge = getExportBridge()!
      const theme = bridge.collectExportTheme()
      const renderedAssets = await bridge.renderCustomBlocks(markdown, 'html')
      // 宿主生成主题化 HTML（不落盘），auto_print 注入后打开预览窗口，
      // load 300ms 后自动弹系统打印对话框 —— 用户"存储为 PDF"
      const html = await invoke<string>('generate_export_html', {
        workspaceRoot: workspaceRoot(),
        notePath: activeNotePath,
        markdown,
        theme,
        renderedAssets,
        autoPrint: true,
      })
      await invoke('open_print_preview', { html })
      return ''
    })
  }, [activeNoteContent, activeNotePath, workspaceRoot, runExport])

  const handleExportHtml = useCallback(async () => {
    const markdown = compactMarkdown(activeNoteContent)
    await runExport('html', async () => {
      const bridge = getExportBridge()!
      const theme = bridge.collectExportTheme()
      const renderedAssets = await bridge.renderCustomBlocks(markdown, 'html')
      // HTML 落盘下载目录；渲染产物/图片已内嵌，单文件离线可用
      const result = await invoke<HostExportResult>('export_html', {
        workspaceRoot: workspaceRoot(),
        notePath: activeNotePath,
        markdown,
        theme,
        renderedAssets,
        fileName: noteName,
      })
      return result.path
    })
  }, [activeNoteContent, activeNotePath, noteName, workspaceRoot, runExport])

  // 仅 Markdown 笔记显示导出入口（非 md 返回 null 隐藏整个下拉）
  if (!isMarkdown) {
    return null
  }

  return (
    <div ref={menuRef} className="relative">
      <button
        onClick={() => setMenuOpen(!menuOpen)}
        className="flex items-center justify-center w-6 h-6 rounded hover:bg-[var(--bg-hover)] cursor-pointer"
        style={{ color: menuOpen ? 'var(--theme-color)' : 'var(--text-primary)' }}
        title={strings.tooltip}
        aria-label={strings.tooltip}
      >
        <ExportIcon size={size} />
      </button>
      {menuOpen && (
        <div
          className="absolute right-0 top-full mt-1 z-50 rounded-lg py-1 min-w-[140px]"
          style={{
            background: 'var(--bg-secondary)',
            border: '1px solid var(--border-color)',
            boxShadow: '0 4px 12px rgba(0,0,0,0.15)',
          }}
        >
          <button
            onClick={handleExportDocx}
            disabled={isExporting || !hasContent}
            className="flex items-center gap-2 w-full px-3 py-1.5 text-left text-[11px] hover:bg-[var(--bg-hover)] disabled:opacity-50"
            style={{
              color: 'var(--text-primary)',
              background: 'transparent',
              border: 'none',
              cursor: isExporting || !hasContent ? 'not-allowed' : 'pointer',
            }}
            aria-busy={isExporting}
          >
            <span style={{ fontSize: 10 }}>W</span>
            {strings.wordMenu}
          </button>
          <button
            onClick={handleExportPdf}
            disabled={isExporting || !hasContent}
            className="flex items-center gap-2 w-full px-3 py-1.5 text-left text-[11px] hover:bg-[var(--bg-hover)] disabled:opacity-50"
            style={{
              color: 'var(--text-primary)',
              background: 'transparent',
              border: 'none',
              cursor: isExporting || !hasContent ? 'not-allowed' : 'pointer',
            }}
            aria-busy={isExporting}
          >
            <span style={{ fontSize: 10 }}>P</span>
            {strings.pdfMenu}
          </button>
          <button
            onClick={handleExportHtml}
            disabled={isExporting || !hasContent}
            className="flex items-center gap-2 w-full px-3 py-1.5 text-left text-[11px] hover:bg-[var(--bg-hover)] disabled:opacity-50"
            style={{
              color: 'var(--text-primary)',
              background: 'transparent',
              border: 'none',
              cursor: isExporting || !hasContent ? 'not-allowed' : 'pointer',
            }}
            aria-busy={isExporting}
          >
            <span style={{ fontSize: 10 }}>H</span>
            {strings.htmlMenu}
          </button>
        </div>
      )}
    </div>
  )
}

// ─── Placeholder panel ────────────────────────────────────────────────────

function ExportPanel(_props: PluginPanelProps): ReactNode {
  return null
}

// manifest 静态字段单一来源是工程根的 ../manifest.json；icon/panel/
// toolbarButton 组件由 definePlugin 注入。
// 供回归测试直接挂载工具栏按钮（宿主运行时仍走 definePlugin 注册）
export { ExportToolbarButton }

export default definePlugin(manifestJson, {
  icon: ExportIcon,
  panel: ExportPanel,
  toolbarButton: ExportToolbarButton,
})
