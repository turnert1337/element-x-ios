//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
import PaperKit
import PencilKit
import SwiftUI

@available(iOS 26, *)
struct ImageDrawingEditor: UIViewControllerRepresentable {
    let imageURL: URL
    /// Called with the drawing when Done is tapped with something drawn.
    let onDone: (ImageDrawing) -> Void
    /// Called for Cancel, and for Done with nothing drawn.
    let onCancel: () -> Void
    
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: ImageDrawingViewController(imageURL: imageURL, onDone: onDone, onCancel: onCancel))
    }
    
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) { }
}

@available(iOS 26, *)
private final class ImageDrawingViewController: UIViewController, PKToolPickerObserver {
    private let onDone: (ImageDrawing) -> Void
    private let onCancel: () -> Void
    /// The aspect ratio of the picture on screen.
    private let pixelSize: CGSize?
    
    private let imageView: UIImageView
    private let paperViewController: PaperMarkupViewController
    private let toolPicker = PKToolPicker(toolItems: [PKToolPickerInkingItem(type: .pen, color: .systemRed),
                                                      PKToolPickerInkingItem(type: .marker),
                                                      PKToolPickerEraserItem(type: .bitmap)])
    
    private let drawingUndoManager = UndoManager()
    /// The space the picture was last fitted into.
    private var fittedSize: CGSize?
    private var cancellables = Set<AnyCancellable>()
    private lazy var cancelButton = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel() })
    private lazy var doneButton = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.done() })
    private lazy var undoButton = UIBarButtonItem(systemItem: .undo, primaryAction: UIAction { [weak self] _ in self?.undo() })
    private lazy var redoButton = UIBarButtonItem(systemItem: .redo, primaryAction: UIAction { [weak self] _ in self?.redo() })
    
    // PaperKit takes the responder chain's manager, which would otherwise be the window's, shared with the caption behind the sheet.
    override var undoManager: UndoManager? {
        drawingUndoManager
    }
    
    init(imageURL: URL, onDone: @escaping (ImageDrawing) -> Void, onCancel: @escaping () -> Void) {
        self.onDone = onDone
        self.onCancel = onCancel
        let pixelSize = ImageDrawingRenderer.orientedPixelSize(ofImageAt: imageURL)
        self.pixelSize = pixelSize
        imageView = UIImageView(image: pixelSize.flatMap {
            ImageDrawingRenderer.previewImage(ofImageAt: imageURL, maxPixelSize: ImageDrawingRenderer.previewMaxPixelSize(forPixelSize: $0))
        })
        
        var featureSet = FeatureSet.latest
        featureSet.features = [.drawing]
        featureSet.shapes = []
        featureSet.inks = [.pen, .marker]
        paperViewController = PaperMarkupViewController(supportedFeatureSet: featureSet)
        
        super.init(nibName: nil, bundle: nil)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        setUpPaperViewController()
        setUpToolPicker()
        setUpNavigationItems()
        observeUndoManager()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        paperViewController.becomeFirstResponder()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layOutPicture()
        updateUndoRedoVisibility()
    }
    
    // MARK: - PKToolPickerObserver
    
    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        view.setNeedsLayout()
    }
    
    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        view.setNeedsLayout()
    }
    
    // MARK: - Private
    
    private func setUpPaperViewController() {
        paperViewController.directTouchMode = .drawing
        // Otherwise the ink shows in dark mode colours, black as white.
        paperViewController.overrideUserInterfaceStyle = .light
        paperViewController.view.backgroundColor = .black
        addChild(paperViewController)
        view.addSubview(paperViewController.view)
        paperViewController.didMove(toParent: self)
    }
    
    private func setUpToolPicker() {
        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.overrideUserInterfaceStyle = .dark
        toolPicker.showsDrawingPolicyControls = false
        toolPicker.stateAutosaveName = nil
        toolPicker.addObserver(paperViewController)
        toolPicker.addObserver(self)
        paperViewController.pencilKitResponderState.activeToolPicker = toolPicker
        paperViewController.pencilKitResponderState.toolPickerVisibility = .visible
        // PaperKit only follows later changes, it would start with its own black pen.
        if let tool = toolPicker.selectedToolItem.tool {
            paperViewController.drawingTool = tool
        }
    }
    
    private func setUpNavigationItems() {
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItems = [doneButton, redoButton, undoButton]
        updateUndoRedoAvailability()
    }
    
    /// Gestures, Cmd-Z and the palette change the history without going through the buttons.
    private func observeUndoManager() {
        let names: [Notification.Name] = [.NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup]
        Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0, object: drawingUndoManager) })
            .sink { [weak self] _ in self?.updateUndoRedoAvailability() }
            .store(in: &cancellables)
    }
    
    /// Fits the whole picture above the docked palette when that space changes, keeping the person's zoom when only the palette moved.
    /// The markup keeps its own coordinates, so the strokes stay on the same spot of the picture.
    private func layOutPicture() {
        guard let pixelSize, imageView.image != nil else {
            return
        }
        
        var available = view.bounds.inset(by: view.safeAreaInsets)
        let obscured = toolPicker.frameObscured(in: view) // Null when the palette floats (iPad): overlap is accepted there.
        if !obscured.isNull {
            available.size.height = max(0, min(available.maxY, obscured.minY) - available.minY)
        }
        guard !available.isEmpty else {
            return
        }
        paperViewController.view.frame = available
        // Fitting on every layout pass would undo the person's zoom.
        guard available.size != fittedSize else {
            return
        }
        let previousSize = fittedSize
        fittedSize = available.size
        // Otherwise PaperKit applies the new frame after the fit below and puts the old zoom back.
        paperViewController.view.layoutIfNeeded()
        
        let markup = paperViewController.markup ?? makeMarkup(fitting: pixelSize, in: available.size)
        let zoomScale = available.width / paperViewController.contentVisibleFrame.width
        let fitScale = scaleToFit(markup, in: available.size)
        paperViewController.zoomRange = fitScale...(fitScale * 8)
        
        // The docked palette expanding or minimising only changes the height, keep the person's zoom then.
        if let previousSize, previousSize.width == available.width, zoomScale > scaleToFit(markup, in: previousSize) * 1.01 {
            return
        }
        paperViewController.setContentVisibleFrame(markup.bounds, animated: false)
    }
    
    private func scaleToFit(_ markup: PaperMarkup, in size: CGSize) -> CGFloat {
        min(size.width / markup.bounds.width, size.height / markup.bounds.height)
    }
    
    /// Sized in points to fit the first layout, so the pens draw with their usual widths.
    private func makeMarkup(fitting pixelSize: CGSize, in size: CGSize) -> PaperMarkup {
        let pictureSize = AVMakeRect(aspectRatio: pixelSize, insideRect: CGRect(origin: .zero, size: size)).size
        let markup = PaperMarkup(bounds: CGRect(origin: .zero, size: pictureSize))
        imageView.frame = markup.bounds
        paperViewController.markup = markup
        paperViewController.contentView = imageView
        return markup
    }
    
    private func updateUndoRedoVisibility() {
        // Only the floating palette (iPad) has undo and redo, the docked one lacks them even on a regular width iPhone in landscape.
        // The obscured frame is also null while the palette is hidden, so check that it's visible.
        let isHidden = toolPicker.isVisible && toolPicker.frameObscured(in: view).isNull
        guard undoButton.isHidden != isHidden else {
            return
        }
        undoButton.isHidden = isHidden
        redoButton.isHidden = isHidden
    }
    
    private func updateUndoRedoAvailability() {
        undoButton.isEnabled = drawingUndoManager.canUndo
        redoButton.isEnabled = drawingUndoManager.canRedo
    }
    
    private func undo() {
        drawingUndoManager.undo()
    }
    
    private func redo() {
        drawingUndoManager.redo()
    }
    
    private func done() {
        cancelButton.isEnabled = false
        doneButton.isEnabled = false
        
        guard let markup = paperViewController.markup, !markup.contentsRenderFrame.isEmpty else {
            onCancel()
            return
        }
        
        onDone(ImageDrawing(markup: markup))
    }
}
