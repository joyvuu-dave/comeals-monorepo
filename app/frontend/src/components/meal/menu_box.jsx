import { useEffect, useRef, useState } from "react";
import { observer } from "mobx-react-lite";
import { useStore } from "../../helpers/store_context";

import { SAVE_DEBOUNCE_MS } from "../../helpers/helpers";

const styles = {
  main: {
    gridArea: "a3",
    display: "grid",
    gridTemplateRows: "1fr 4fr",
    border: "1px solid",
  },
  text: {
    height: "100%",
    resize: "none",
    opacity: "1",
    visibility: "visible",
    fontSize: "1.25rem",
    whiteSpace: "pre-wrap",
  },
  notSaved: {
    color: "var(--vivid-red)",
    fontWeight: "bold",
    alignSelf: "center",
  },
};

function DebouncedTextarea(props) {
  const [value, setValue] = useState(props.value || "");
  const timeoutRef = useRef(null);
  // Typed text the debounce has not delivered yet, or null.
  const pendingValueRef = useRef(null);

  // The flush handlers must call the LATEST onChange, exactly as the
  // class read this.props.onChange at fire time.
  const onChangeRef = useRef(props.onChange);
  onChangeRef.current = props.onChange;

  // Sync down a prop change the way componentDidUpdate did: only when
  // the prop itself changed and disagrees with what is on screen.
  const prevPropValueRef = useRef(props.value);
  useEffect(
    function () {
      if (prevPropValueRef.current !== props.value) {
        prevPropValueRef.current = props.value;
        setValue(function (current) {
          return props.value !== current ? props.value || "" : current;
        });
      }
    },
    [props.value],
  );

  // The instance is keyed to its meal, so unmount means that meal is
  // leaving the screen. Deliver any undelivered text now — dropping
  // it would lose typing, and letting the timer fire later would
  // deliver it after the callbacks' meal is gone.
  useEffect(function () {
    return function () {
      clearTimeout(timeoutRef.current);
      if (pendingValueRef.current !== null) {
        onChangeRef.current(pendingValueRef.current);
        pendingValueRef.current = null;
      }
    };
  }, []);

  const handleChange = (e) => {
    var val = e.target.value;
    setValue(val);
    pendingValueRef.current = val;
    if (props.onTyping) {
      props.onTyping();
    }
    clearTimeout(timeoutRef.current);
    timeoutRef.current = setTimeout(() => {
      pendingValueRef.current = null;
      onChangeRef.current(val);
    }, props.debounceTimeout || SAVE_DEBOUNCE_MS);
  };

  return (
    <textarea
      value={value}
      onChange={handleChange}
      className={props.className}
      style={props.style}
      disabled={props.disabled}
      aria-label={props["aria-label"]}
    />
  );
}

const MenuBox = observer(() => {
  const store = useStore();
  // Bind the node at render time, and key the textarea to it. The
  // debounced flush and the unmount flush then always save to the
  // meal the text was typed on — reading store.meal at flush time
  // saved late text onto whatever meal the user had switched to.
  const meal = store.meal;
  return (
    <div style={styles.main} className="button-border-radius">
      <div className="flex space-between title">
        <h2 className="w-15">Menu</h2>
        {meal && meal.descriptionNotSaved && (
          <span style={styles.notSaved} role="status">
            Not saved — will retry
          </span>
        )}
      </div>
      <div>
        <DebouncedTextarea
          key={meal ? meal.id : "no-meal"}
          className={store.editDescriptionMode ? "" : "offwhite"}
          style={styles.text}
          value={meal && meal.description}
          onChange={(val) => store.setDescriptionOn(meal, val)}
          onTyping={() => store.noteMenuTyping(meal)}
          disabled={
            // Frozen while the next meal loads: the box shows "" until
            // the data arrives, and text typed into that emptiness would
            // overwrite the real menu that has not shown yet.
            store.mealLoading ||
            !store.editDescriptionMode ||
            (meal && meal.closed)
          }
          aria-label="Enter meal description"
        />
      </div>
    </div>
  );
});

export default MenuBox;
