import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

/** 对应 Rust 侧 `SettingsView`，见 src-tauri/src/settings.rs */
type ProviderSettings = {
  id: string;
  model: string;
  endpoint: string;
  api_key_url: string;
};

type SettingsView = {
  hotkey: string;
  hotkey_registered: boolean;
  hotkey_error: string | null;
  provider: ProviderSettings;
  languages: { native: string; foreign: string };
  has_api_key: boolean;
};

type Direction = { from: string; to: string };
type Mode = "translate" | "lookup";

/** §4.2 的错误分类。名字与 Rust 侧的 `ErrorKind` 一一对应。 */
type ErrorKind =
  | "NoApiKey"
  | "InvalidApiKey"
  | "RateLimited"
  | "Network"
  | "Timeout"
  | "EmptyClipboard"
  | "TooLong"
  | "ParseError"
  | "Unknown";

type PanelShow = { text: string; mode: Mode; direction: Direction };
type ReqChunk = { request_id: string; delta: string };
type ReqDone = { request_id: string };
type ReqError = { request_id: string; kind: ErrorKind; message: string };

type Stream = {
  /** 事件归属的请求号。0 表示还没有任何请求。 */
  id: number;
  text: string;
  status: "idle" | "loading" | "done" | "error";
  errorKind: ErrorKind | null;
  errorMessage: string;
};

const IDLE: Stream = {
  id: 0,
  text: "",
  status: "idle",
  errorKind: null,
  errorMessage: "",
};

/**
 * 429 之后等多久自动重试。§4.2 只写了「倒计时后自动重试一次」，没定秒数。
 * Gemini 免费层是 15 RPM，即平均每 4 秒一个额度，取 5 秒留一点余量。
 * 这个值是我定的，不是方案规定的。
 */
const RATE_LIMIT_RETRY_SECONDS = 5;

function directionLabel(direction: Direction): string {
  const name = (code: string) => (code === "zh" ? "中" : code.toUpperCase());
  return `${name(direction.from)} → ${name(direction.to)}`;
}

// M1 仍然不做 UI 样式（§10 第 2 条），下面全是最朴素的标签。
export default function App() {
  const [view, setView] = useState<SettingsView | null>(null);
  const [draft, setDraft] = useState("");
  const [saveError, setSaveError] = useState<string | null>(null);

  const [source, setSource] = useState("");
  const [direction, setDirection] = useState<Direction | null>(null);
  const [mode, setMode] = useState<Mode>("translate");
  const [stream, setStream] = useState<Stream>(IDLE);

  const [keyStatus, setKeyStatus] = useState<string>("");
  const [countdown, setCountdown] = useState<number | null>(null);

  /** 本轮原文。重试要用，放 ref 避免闭包拿到旧值。 */
  const requestRef = useRef<{ text: string; mode: Mode; direction: Direction } | null>(null);
  /** 限流自动重试只做一次（§4.2），换新请求时重置。 */
  const rateRetriedRef = useRef(false);

  const refresh = useCallback(async () => {
    const next = await invoke<SettingsView>("load_settings");
    setView(next);
    setDraft(next.hotkey);
    return next;
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const send = useCallback(async (payload: { text: string; mode: Mode; direction: Direction }) => {
    requestRef.current = payload;
    rateRetriedRef.current = false;
    setCountdown(null);
    await invoke<string>("start_request", payload);
  }, []);

  /**
   * 事件按请求号收敛。request_id 单调递增，所以：
   *   - 号比当前小 → 旧请求的残留，丢弃（§4.1 防串台）
   *   - 号比当前大 → 新请求，正文清空重来
   * 这样即使事件比 `start_request` 的返回值先到也不会错乱。
   */
  const applyEvent = useCallback((rawId: string, update: (base: Stream) => Stream) => {
    const id = Number(rawId);
    setStream((prev) => {
      if (id < prev.id) return prev;
      const base: Stream =
        id > prev.id ? { id, text: "", status: "loading", errorKind: null, errorMessage: "" } : prev;
      return update(base);
    });
  }, []);

  useEffect(() => {
    const unlisteners = [
      listen<PanelShow>("panel:show", (event) => {
        const { text, mode: nextMode, direction: nextDirection } = event.payload;
        setSource(text);
        setMode(nextMode);
        setDirection(nextDirection);
        setStream((prev) => ({ ...prev, text: "", status: "loading", errorKind: null, errorMessage: "" }));
        void send({ text, mode: nextMode, direction: nextDirection });
      }),
      listen<ReqChunk>("req:chunk", (event) => {
        const { request_id, delta } = event.payload;
        applyEvent(request_id, (base) => ({ ...base, text: base.text + delta, status: "loading" }));
      }),
      listen<ReqDone>("req:done", (event) => {
        applyEvent(event.payload.request_id, (base) => ({ ...base, status: "done" }));
      }),
      listen<ReqError>("req:error", (event) => {
        const { request_id, kind, message } = event.payload;
        applyEvent(request_id, (base) => ({
          ...base,
          status: "error",
          errorKind: kind,
          errorMessage: message,
        }));
      }),
    ];
    return () => {
      void Promise.all(unlisteners).then((fns) => fns.forEach((fn) => fn()));
    };
  }, [applyEvent, send]);

  const retry = useCallback(() => {
    const payload = requestRef.current;
    if (payload) void send(payload);
  }, [send]);

  // 限流：倒计时结束后自动重试一次（§4.2）
  useEffect(() => {
    if (stream.errorKind !== "RateLimited" || rateRetriedRef.current) return;
    rateRetriedRef.current = true;
    setCountdown(RATE_LIMIT_RETRY_SECONDS);
  }, [stream.errorKind, stream.id]);

  useEffect(() => {
    if (countdown === null) return;
    if (countdown <= 0) {
      setCountdown(null);
      retry();
      return;
    }
    const timer = setTimeout(() => setCountdown(countdown - 1), 1000);
    return () => clearTimeout(timer);
  }, [countdown, retry]);

  async function saveHotkey() {
    setSaveError(null);
    try {
      await invoke("save_settings", { settings: { hotkey: draft } });
      await refresh();
      await invoke("hide_panel");
    } catch (error) {
      setSaveError(String(error));
      await refresh();
    }
  }

  /**
   * 从剪贴板取 Key 并验证。
   *
   * 不做输入框：面板带 `WS_EX_NOACTIVATE`，拿不到键盘焦点，让用户手打
   * 必须先临时摘掉这个样式并抢焦点 —— 那会破坏门禁 0.3（弹窗不夺焦点）。
   * 而取 Key 的路径本来就是「在 AI Studio 复制 → 回来粘贴」，剪贴板里
   * 已经有了，点一下按钮就够，全程不需要焦点。§5.1 的引导也是这个思路。
   */
  async function pasteKey() {
    if (!view) return;
    setKeyStatus("正在读取剪贴板…");
    const key = await invoke<string | null>("read_clipboard_text");
    if (!key) {
      setKeyStatus("剪贴板里没有文本。请先复制 API Key 再点这里。");
      return;
    }
    setKeyStatus("正在验证…");
    try {
      await invoke("validate_api_key", {
        provider: view.provider.id,
        key,
        model: view.provider.model,
      });
      setKeyStatus("验证通过，已保存。");
      await refresh();
      retry();
    } catch (error) {
      setKeyStatus(String(error));
    }
  }

  if (!view) {
    return <div>载入中</div>;
  }

  // 热键注册失败：启动即提示并可当场改键（门禁 0.1a / 0.1b）
  if (!view.hotkey_registered) {
    return (
      <div>
        <div>热键 {view.hotkey} 注册失败，可能已被其他程序占用。</div>
        <div>{view.hotkey_error}</div>
        <div>
          <input autoFocus value={draft} onChange={(e) => setDraft(e.target.value)} />
          <button onClick={() => void saveHotkey()}>保存并立即生效</button>
        </div>
        {saveError ? <div>{saveError}</div> : null}
      </div>
    );
  }

  return (
    <div>
      <div>
        <span>Glim</span>
        {direction ? <span> {directionLabel(direction)}</span> : null}
        {mode === "lookup" ? <span> 查词</span> : null}
      </div>

      <div>原文</div>
      <div>{source}</div>

      <div>结果</div>
      <div>{stream.text}</div>

      {stream.status === "loading" && !stream.text ? <div>正在翻译…</div> : null}

      {stream.status === "error" ? (
        <ErrorCard
          kind={stream.errorKind}
          message={stream.errorMessage}
          provider={view.provider}
          countdown={countdown}
          keyStatus={keyStatus}
          onRetry={retry}
          onPasteKey={() => void pasteKey()}
        />
      ) : null}
    </div>
  );
}

/**
 * 每个错误必须有一句人话 + 至少一个可点击的动作，
 * 禁止空白错误态或纯技术堆栈（§4.2）。
 */
function ErrorCard(props: {
  kind: ErrorKind | null;
  message: string;
  provider: ProviderSettings;
  countdown: number | null;
  keyStatus: string;
  onRetry: () => void;
  onPasteKey: () => void;
}) {
  const { kind, message, provider, countdown, keyStatus, onRetry, onPasteKey } = props;

  if (kind === "NoApiKey" || kind === "InvalidApiKey") {
    return (
      <div>
        <div>{kind === "NoApiKey" ? "还没有配置 API Key。" : "API Key 无效。"}</div>
        <div>1. 打开下面的地址，登录后创建一个免费的 API Key：</div>
        {/* §5.1：地址始终以可选中的纯文本显示，不能只藏在按钮后面 —— 
            AI Studio 改版导致链接失效时，用户至少还能手动访问。 */}
        <div>
          <input readOnly value={provider.api_key_url} onFocus={(e) => e.currentTarget.select()} />
        </div>
        <div>2. 复制那串 Key，然后点这里：</div>
        <div>
          <button onClick={onPasteKey}>从剪贴板粘贴 Key 并验证</button>
        </div>
        {keyStatus ? <div>{keyStatus}</div> : null}
        {/* §5.1：隐私告知不能省、不能折叠、不能弱化。 */}
        <div>
          注意：免费层的输入和输出可能被 Google 用于改进产品。介意的话请改用付费层，
          或在设置里换成其他 Provider。
        </div>
      </div>
    );
  }

  if (kind === "RateLimited") {
    return (
      <div>
        <div>请求太频繁。{countdown !== null ? `${countdown} 秒后自动重试…` : ""}</div>
        <button onClick={onRetry}>立即重试</button>
      </div>
    );
  }

  if (kind === "EmptyClipboard") {
    return <div>剪贴板里没有文本。复制一段文字再按热键。</div>;
  }

  if (kind === "TooLong") {
    return <div>{message}</div>;
  }

  return (
    <div>
      <div>{message || "出了点问题。"}</div>
      <button onClick={onRetry}>重试</button>
    </div>
  );
}
