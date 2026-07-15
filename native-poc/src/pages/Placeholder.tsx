/** 尚未接线的页面占位(诚实标注，不假装做完)。逐页替换为真实实现。 */
export default function Placeholder({
  title,
  note,
}: {
  title: string;
  note: string;
}) {
  return (
    <>
      <div className="topbar">
        <h1>{title}</h1>
      </div>
      <div className="scroll">
        <div className="placeholder enter">
          <div className="ph-badge">建设中</div>
          <p>{note}</p>
        </div>
      </div>
    </>
  );
}
