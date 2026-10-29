/** Un robot de la biblioteca de MuJoCo Menagerie (catálogo incluido en la app). */
export type LibraryRobot = {
  /** <carpeta>/<modelo> */
  id: string;
  name: string;
  category: string;
  /** Ruta del MJCF dentro del repositorio. */
  xml: string;
  /** Vista previa dentro del repositorio. */
  image?: string | null;
  /** Todo lo que hay que descargar. */
  files: string[];
};

export type LibraryCatalog = {
  /** Repositorio en GitHub. */
  source: string;
  /** Versión fija: el catálogo y los archivos siempre coinciden. */
  commit: string;
  robots: LibraryRobot[];
};
