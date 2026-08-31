import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

/** 对应 Rust 侧 `SettingsView`，见 src-tauri/src/settings.rs */
type SettingsView = {
  hotkey: string;
  hotkey_registered: boolean;
  hotkey_error: string | null;
};

// M0 不做任何 UI 样式（§10 第 2 条），下面全是最朴素的 div。
export default function App() {
  const [view, setView] = useState<SettingsView | null>(null);
  const [draft, setDraft] = useState("");
  const [saveError, setSaveError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    const next = await invoke<SettingsView>("load_settings");
    setView(next);
    setDraft(next.hotkey);
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function save() {
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
          <button onClick={() => void save()}>保存并立即生效</button>
        </div>
        {saveError ? <div>{saveError}</div> : null}
      </div>
    );
  }

  // 正常骨架屏。原文与结果区在 M1 才有内容。
  return (
    <div>
      <div>Glim</div>
      <div>热键 {view.hotkey}</div>
      <div>原文</div>
      <div>结果</div>
    </div>
  );
}
