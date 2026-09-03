import { ErrorPage } from './ErrorPage';

export function NotFound() {
  return (
    <ErrorPage
      code={404}
      title="Page not found"
      message="The page you requested does not exist or may have moved."
    />
  );
}
