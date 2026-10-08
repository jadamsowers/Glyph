/// Which pipeline variant suits an image.
public enum ImageKind: String, Sendable, CaseIterable {
    case logo, photo
}

/// How region outlines are emitted.
public enum TracingMode: String, Sendable, CaseIterable {
    /// Adjacent regions share identical boundary curves; holes are cut out.
    case sharedEdges
    /// Regions are painted largest-first using only their outer boundary.
    case stacked
}
