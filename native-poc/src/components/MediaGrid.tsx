import { type Item, type LoginResult, posterUrl, thumbUrl } from "../lib/api";
import { IconLibrary, IconPlay } from "../app/icons";

type Variant = "poster" | "thumb";

type Props = {
  items: Item[];
  session: LoginResult;
  onSelect: (it: Item) => void;
  rail?: boolean;
  variant?: Variant;
};

export default function MediaGrid({ items, session, onSelect, rail, variant = "poster" }: Props) {
  const cls = variant === "thumb" ? "thumb-grid" : "poster-grid";
  return (
    <div className={rail ? `rail ${variant}` : cls}>
      {items.map((it, i) => (
        <MediaCard
          key={it.id}
          it={it}
          session={session}
          onClick={() => onSelect(it)}
          index={i}
          variant={variant}
        />
      ))}
    </div>
  );
}

function MediaCard({
  it,
  session,
  onClick,
  index,
  variant,
}: {
  it: Item;
  session: LoginResult;
  onClick: () => void;
  index: number;
  variant: Variant;
}) {
  const progress =
    !it.is_folder && it.resume_secs > 0 && it.runtime_secs > 0
      ? Math.min(100, (it.resume_secs / it.runtime_secs) * 100)
      : 0;
  const thumb = variant === "thumb";
  const src = thumb ? thumbUrl(session, it.id) : posterUrl(session, it.id);
  return (
    <button
      type="button"
      className={`card ${thumb ? "card-thumb" : "card-poster"} enter`}
      style={{ animationDelay: `${Math.min(index, 12) * 26}ms` }}
      onClick={onClick}
      title={it.name}
    >
      <div className={thumb ? "art art-thumb" : "art art-poster"}>
        {it.has_primary ? (
          <img
            src={src}
            loading="lazy"
            onError={(e) => ((e.target as HTMLImageElement).style.visibility = "hidden")}
          />
        ) : (
          <div className="art-fallback">
            {it.is_folder ? <IconLibrary size={32} /> : <IconPlay size={28} />}
          </div>
        )}
        <span className="art-play">
          <IconPlay size={18} />
        </span>
        {progress > 0 && (
          <div className="resume">
            <div className="resume-fill" style={{ width: `${progress}%` }} />
          </div>
        )}
      </div>
      <div className="cap">{it.name}</div>
    </button>
  );
}
