import {
  forwardRef,
  createContext,
  useContext,
  useState,
  type ReactNode,
  type HTMLAttributes,
  type ButtonHTMLAttributes,
} from 'react';
import { cn } from '../lib/cn';

interface TabsContextValue {
  active: string;
  setActive: (id: string) => void;
}

const TabsContext = createContext<TabsContextValue>({ active: '', setActive: () => {} });

export interface TabsProps extends HTMLAttributes<HTMLDivElement> {
  defaultTab?: string;
  value?: string;
  onValueChange?: (value: string) => void;
  children: ReactNode;
}

export const Tabs = forwardRef<HTMLDivElement, TabsProps>(
  ({ defaultTab = '', value, onValueChange, children, className, ...rest }, ref) => {
    const [internal, setInternal] = useState(defaultTab);
    const active = value ?? internal;
    const setActive = (id: string) => {
      setInternal(id);
      onValueChange?.(id);
    };

    return (
      <TabsContext.Provider value={{ active, setActive }}>
        <div ref={ref} className={cn('flex flex-col', className)} {...rest}>
          {children}
        </div>
      </TabsContext.Provider>
    );
  },
);
Tabs.displayName = 'Tabs';

export interface TabListProps extends HTMLAttributes<HTMLDivElement> {
  children: ReactNode;
}

export const TabList = forwardRef<HTMLDivElement, TabListProps>(
  ({ children, className, ...rest }, ref) => (
    <div
      ref={ref}
      role="tablist"
      className={cn(
        'flex gap-1 p-1 rounded-xl bg-surface-2 border border-border',
        className,
      )}
      {...rest}
    >
      {children}
    </div>
  ),
);
TabList.displayName = 'TabList';

export interface TabTriggerProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  value: string;
  children: ReactNode;
}

export const TabTrigger = forwardRef<HTMLButtonElement, TabTriggerProps>(
  ({ value, children, className, ...rest }, ref) => {
    const { active, setActive } = useContext(TabsContext);
    const isActive = active === value;
    return (
      <button
        ref={ref}
        role="tab"
        aria-selected={isActive}
        onClick={() => setActive(value)}
        className={cn(
          'flex-1 px-3 py-1.5 text-sm rounded-lg font-medium transition-colors',
          isActive
            ? 'bg-surface text-fg shadow-sm'
            : 'text-muted hover:text-fg',
          className,
        )}
        {...rest}
      >
        {children}
      </button>
    );
  },
);
TabTrigger.displayName = 'TabTrigger';

export interface TabContentProps extends HTMLAttributes<HTMLDivElement> {
  value: string;
  children: ReactNode;
}

export const TabContent = forwardRef<HTMLDivElement, TabContentProps>(
  ({ value, children, className, ...rest }, ref) => {
    const { active } = useContext(TabsContext);
    if (active !== value) return null;
    return (
      <div
        ref={ref}
        role="tabpanel"
        className={cn('mt-4', className)}
        {...rest}
      >
        {children}
      </div>
    );
  },
);
TabContent.displayName = 'TabContent';
