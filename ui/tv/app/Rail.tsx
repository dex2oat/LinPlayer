import { FocusContext, useFocusable } from "@noriginmedia/norigin-spatial-navigation";
import { Icon } from "./icons";
import { NAV, NAV_FOOT, type NavItem, type PageId } from "./nav";

/** 导航轨。图标在上、文字在下 —— 横排是 PC 侧栏的做法,TV 上远看会糊成一片。 */
export default function Rail({
  page,
  onGo,
}: {
  page: PageId;
  onGo: (p: PageId) => void;
}) {
  const { ref, focusKey } = useFocusable({
    focusKey: "RAIL",
    saveLastFocusedChild: true,
    trackChildren: true,
    /* 从内容区按左回到轨上时,落在**当前页**那一项,而不是上次停的那一项 ——
       否则用户会在"我现在在哪一页"上产生歧义。 */
    preferredChildFocusKey: `RAIL-${page}`,
  });

  return (
    <FocusContext.Provider value={focusKey}>
      <div ref={ref} className="rail">
        <div className="brand">
          <div className="lg" />
          <div className="nm">LinPlayer</div>
        </div>
        {NAV.map((n) => (
          <RailItem key={n.id} n={n} on={page === n.id} onGo={onGo} />
        ))}
        <div className="spring" />
        <div className="sep" />
        {NAV_FOOT.map((n) => (
          <RailItem key={n.id} n={n} on={page === n.id} onGo={onGo} />
        ))}
      </div>
    </FocusContext.Provider>
  );
}

function RailItem({
  n,
  on,
  onGo,
}: {
  n: NavItem;
  on: boolean;
  onGo: (p: PageId) => void;
}) {
  const { ref, focused } = useFocusable<object, HTMLDivElement>({
    focusKey: `RAIL-${n.id}`,
    onEnterPress: () => onGo(n.id),
  });
  return (
    <div
      ref={ref}
      className={`ritem${on ? " on" : ""}${focused ? " foc" : ""}`}
    >
      <Icon n={n.icon} className="ic ic-rail" />
      <span>{n.label}</span>
    </div>
  );
}
