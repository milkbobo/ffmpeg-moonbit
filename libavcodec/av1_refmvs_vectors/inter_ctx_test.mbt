///|
test "AV1 reference tree contexts count forward and backward neighbours" {
  let top : @libavcodec.Av1InterNeighbor = {
    intra: false, comp_type: 0, ref0: 0, ref1: -1,
    filter0: 3, filter1: 3,
  }
  let left : @libavcodec.Av1InterNeighbor = {
    intra: false, comp_type: 0, ref0: 6, ref1: -1,
    filter0: 3, filter1: 3,
  }
  inspect(@libavcodec.av1_inter_ref_tree_ctx(Some(top), Some(left), 0), content="1")
  inspect(@libavcodec.av1_inter_ref_tree_ctx(Some(top), Some(left), 1), content="2")
  inspect(@libavcodec.av1_inter_ref_tree_ctx(Some(top), Some(left), 4), content="0")
  inspect(@libavcodec.av1_inter_comp_ctx(Some(top), Some(left)), content="1")
  inspect(@libavcodec.av1_inter_comp_dir_ctx(Some(top), Some(left)), content="1")
}

///|
test "AV1 compound direction distinguishes uni and bidirectional pairs" {
  let uni : @libavcodec.Av1InterNeighbor = {
    intra: false, comp_type: 1, ref0: 0, ref1: 1,
    filter0: 3, filter1: 3,
  }
  let bi : @libavcodec.Av1InterNeighbor = {
    intra: false, comp_type: 1, ref0: 0, ref1: 6,
    filter0: 3, filter1: 3,
  }
  inspect(@libavcodec.av1_inter_comp_dir_ctx(Some(uni), None), content="4")
  inspect(@libavcodec.av1_inter_comp_dir_ctx(Some(bi), None), content="0")
  inspect(@libavcodec.av1_inter_comp_dir_ctx(Some(uni), Some(bi)), content="2")
  inspect(@libavcodec.av1_inter_comp_ctx(Some(uni), Some(bi)), content="4")
  inspect(@libavcodec.av1_inter_drl_ctx(640, 639), content="1")
  inspect(@libavcodec.av1_inter_drl_ctx(639, 639), content="2")
}

///|
test "AV1 intra filter mask and joint contexts follow neighbour state" {
  let top : @libavcodec.Av1InterNeighbor = {
    intra: true, comp_type: 0, ref0: -1, ref1: -1,
    filter0: 3, filter1: 3,
  }
  let left : @libavcodec.Av1InterNeighbor = {
    intra: false, comp_type: 3, ref0: 6, ref1: 0,
    filter0: 2, filter1: 1,
  }
  inspect(@libavcodec.av1_inter_intra_ctx(Some(top), None), content="2")
  inspect(@libavcodec.av1_inter_intra_ctx(Some(top), Some(top)), content="3")
  inspect(@libavcodec.av1_inter_filter_ctx(Some(top), Some(left), 0, 0, 6), content="2")
  inspect(@libavcodec.av1_inter_filter_ctx(Some(top), Some(left), 1, 1, 6), content="5")
  inspect(@libavcodec.av1_inter_mask_comp_ctx(left, left), content="2")
  inspect(@libavcodec.av1_inter_jnt_comp_ctx(7, 10, 8, 12, top, left), content="4")
}
