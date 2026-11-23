import { useEffect, useRef, useState } from 'react';

/**
 * Builds touch responders once and lets their callbacks read the component's latest props.
 * `create` is called a single time; `latest()` is only ever called from touch callbacks.
 */
export function useResponder<Props, Responders>(props: Props, create: (latest: () => Props) => Responders): Responders {
  const ref = useRef(props);
  useEffect(() => {
    ref.current = props;
  });
  // eslint-disable-next-line react-hooks/refs -- the ref is read when a finger moves, never while rendering
  const [responders] = useState(() => create(() => ref.current));
  return responders;
}
