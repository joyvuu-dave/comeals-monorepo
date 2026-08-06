import { useEffect, useRef } from "react";

// A ref that is true while the component is mounted. Requests outlive
// a closed modal; callbacks check this flag so they never set state
// after unmount (the hooks version of the class's _isMounted).
export default function useMountedRef() {
  const mountedRef = useRef(true);
  useEffect(function () {
    mountedRef.current = true;
    return function () {
      mountedRef.current = false;
    };
  }, []);
  return mountedRef;
}
